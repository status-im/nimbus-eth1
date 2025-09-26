# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  ../execution_chain/compile_info

import
  std/[net, options],
  chronicles,
  eth/net/nat,
  metrics,
  stew/byteutils,
  ./rpc,
  ./version_info,
  ./constants,
  ./nimbus_desc,
  ./nimbus_import,
  ./core/block_import,
  ./core/lazy_kzg,
  ./core/chain/forked_chain/chain_serialize,
  ./db/core_db/persistent,
  ./db/storage_types,
  ./sync/wire_protocol,
  ./common/chain_config_hash,
  ./portal/portal,
  ./networking/[bootnodes, netkeys],
  beacon_chain/[nimbus_binary_common, process_state],
  beacon_chain/validators/keystore_management

const
  DontQuit = low(int)
    ## To be used with `onException()` or `onCancelledException()`

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template onException(
    quitCode: static[int];
    info: static[string];
    code: untyped) =
  try:
    code
  except CatchableError as e:
    when quitCode == DontQuit:
      error info, error=($e.name), msg=e.msg
    else:
      fatal info, error=($e.name), msg=e.msg
      quit(quitCode)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc basicServices(nimbus: NimbusNode, conf: NimbusConf, com: CommonRef) =
  # Setup the chain
  let fc = ForkedChainRef.init(com,
    eagerStateRoot = conf.eagerStateRootCheck,
    persistBatchSize = conf.persistBatchSize,
    enableQueue = true)
  fc.deserialize().isOkOr:
    warn "Loading block DAG from database", msg=error

  nimbus.fc = fc
  # Setup history expiry and portal

  QuitFailure.onException("Cannot initialise RPC client history"):
    nimbus.fc.portal = HistoryExpiryRef.init(conf, com)

  # txPool must be informed of active head
  # so it can know the latest account state
  # e.g. sender nonce, etc
  nimbus.txPool = TxPoolRef.new(nimbus.fc)
  nimbus.beaconEngine = BeaconEngineRef.new(nimbus.txPool)

proc manageAccounts(nimbus: NimbusNode, conf: NimbusConf) =
  if conf.keyStoreDir.len > 0:
    nimbus.accountsManager[].loadKeystores(conf.keyStoreDir).isOkOr:
      fatal "Load keystore error", msg = error
      quit(QuitFailure)

  if string(conf.importKey).len > 0:
    nimbus.accountsManager[].importPrivateKey(string conf.importKey).isOkOr:
      fatal "Import private key error", msg = error
      quit(QuitFailure)

proc setupP2P(nimbus: NimbusNode, conf: NimbusConf, com: CommonRef) =
  ## Creating P2P Server
  let
    keypair = nimbus.rng[].getNetKeys(conf.netKey).valueOr:
      fatal "Get network keys error", msg = error
      quit(QuitFailure)
    natId = NimbusName & " " & NimbusVersion
    (extIp, extTcpPort, extUdpPort) =
      setupAddress(conf.nat, conf.listenAddress, conf.tcpPort, conf.udpPort, natId)
    address = enode.Address(
      ip: extIp.valueOr(conf.listenAddress),
      tcpPort: extTcpPort.valueOr(conf.tcpPort),
      udpPort: extUdpPort.valueOr(conf.udpPort),
    )

    bootstrapNodes = conf.getBootstrapNodes()
    fc = nimbus.fc

  func forkIdProc(): ForkID =
    let header = fc.latestHeader()
    com.forkId(header.number, header.timestamp)

  func compatibleForkIdProc(id: ForkID): bool =
    com.compatibleForkId(id)

  let forkIdProcs = ForkIdProcs(
    forkId: forkIdProc,
    compatibleForkId: compatibleForkIdProc,
  )

  nimbus.ethNode = newEthereumNode(
    keypair, address, conf.networkId, conf.agentString,
    minPeers = conf.maxPeers,
    bootstrapNodes = bootstrapNodes,
    bindUdpPort = conf.udpPort, bindTcpPort = conf.tcpPort,
    bindIp = conf.listenAddress,
    rng = nimbus.rng,
    forkIdProcs = forkIdProcs)

  # Add protocol capabilities
  nimbus.wire = nimbus.ethNode.addEthHandlerCapability(nimbus.txPool)

  # Connect directly to the static nodes
  let staticPeers = conf.getStaticPeers()
  if staticPeers.len > 0:
    nimbus.peerManager = PeerManagerRef.new(
      nimbus.ethNode.peerPool,
      conf.reconnectInterval,
      conf.reconnectMaxRetry,
      staticPeers
    )
    nimbus.peerManager.start()

  # Start Eth node
  if conf.maxPeers > 0:
    let discovery = conf.getDiscoveryFlags()
    nimbus.ethNode.connectToNetwork(
      enableDiscV4 = DiscoveryType.V4 in discovery,
      enableDiscV5 = DiscoveryType.V5 in discovery,
    )

  # Initalise beacon sync descriptor.
  var syncerShouldRun = (conf.maxPeers > 0 or staticPeers.len > 0) and
                        conf.engineApiServerEnabled()

  # The beacon sync descriptor might have been pre-allocated with additional
  # features. So do not override.
  if nimbus.beaconSyncRef.isNil:
    nimbus.beaconSyncRef = BeaconSyncRef.init()
  else:
    syncerShouldRun = true

  # Configure beacon syncer.
  nimbus.beaconSyncRef.config(nimbus.ethNode, nimbus.fc, conf.maxPeers)

  # Optional for pre-setting the sync target (e.g. for debugging)
  if conf.beaconSyncTarget.isSome():
    syncerShouldRun = true
    let hex = conf.beaconSyncTarget.unsafeGet
    if not nimbus.beaconSyncRef.configTarget(hex, conf.beaconSyncTargetIsFinal):
      fatal "Error parsing hash32 argument for --debug-beacon-sync-target",
        hash32=hex
      quit QuitFailure

  # Deactivating syncer if there is definitely no need to run it. This
  # avoids polling (i.e. waiting for instructions) and some logging.
  if not syncerShouldRun:
    nimbus.beaconSyncRef = BeaconSyncRef(nil)

proc init*(T: type NimbusNode, conf: NimbusConf, com: CommonRef): T =
  let nimbus = NimbusNode(
    accountsManager: new AccountsManager,
    rng: newRng(),
  )

  basicServices(nimbus, conf, com)
  manageAccounts(nimbus, conf)
  setupP2P(nimbus, conf, com)
  setupRpc(nimbus, conf, com)

  # Not starting syncer if there is definitely no way to run it. This
  # avoids polling (i.e. waiting for instructions) and some logging.
  if not nimbus.beaconSyncRef.isNil and
      not nimbus.beaconSyncRef.start():
    nimbus.beaconSyncRef = BeaconSyncRef(nil)

  nimbus


proc preventLoadingDataDirForTheWrongNetwork(db: CoreDbRef; conf: NimbusConf) =
  proc writeDataDirId(kvt: CoreDbTxRef, calculatedId: Hash32) =
    info "Writing data dir ID", ID=calculatedId
    kvt.put(dataDirIdKey().toOpenArray, calculatedId.data).isOkOr:
      fatal "Cannot write data dir ID", ID=calculatedId
      quit(QuitFailure)
    db.persist(kvt)

  let
    kvt = db.baseTxFrame()
    calculatedId = calcHash(conf.networkId, conf.networkParams)
    dataDirIdBytes = kvt.get(dataDirIdKey().toOpenArray).valueOr:
      # an empty database
      writeDataDirId(kvt, calculatedId)
      return

  if conf.rewriteDatadirId:
    writeDataDirId(kvt, calculatedId)
    return

  if calculatedId.data != dataDirIdBytes:
    fatal "Data dir already initialized with other network configuration",
      get=dataDirIdBytes.toHex,
      expected=calculatedId
    quit(QuitFailure)

proc setupCommonRef*(conf: NimbusConf, taskpool: Taskpool): CommonRef =
  # Trusted setup is needed for processing Cancun+ blocks
  # If user not specify the trusted setup, baked in
  # trusted setup will be loaded, lazily.
  if conf.trustedSetupFile.isSome:
    let fileName = conf.trustedSetupFile.get()
    let res = lazy_kzg.loadTrustedSetup(fileName, 0)
    if res.isErr:
      fatal "Cannot load Kzg trusted setup from file", msg=res.error
      quit(QuitFailure)

  let coreDB = AristoDbRocks.newCoreDbRef(
      conf.dataDir,
      conf.dbOptions(noKeyCache = conf.cmd == NimbusCmd.`import`))

  preventLoadingDataDirForTheWrongNetwork(coreDB, conf)

  let com = CommonRef.new(
    db = coreDB,
    taskpool = taskpool,
    networkId = conf.networkId,
    params = conf.networkParams,
    statelessProviderEnabled = conf.statelessProviderEnabled,
    statelessWitnessValidation = conf.statelessWitnessValidation)

  if conf.extraData.len > 32:
    warn "ExtraData exceeds 32 bytes limit, truncate",
      extraData=conf.extraData,
      len=conf.extraData.len

  if conf.gasLimit > GAS_LIMIT_MAXIMUM or
     conf.gasLimit < GAS_LIMIT_MINIMUM:
    warn "GasLimit not in expected range, truncate",
      min=GAS_LIMIT_MINIMUM,
      max=GAS_LIMIT_MAXIMUM,
      get=conf.gasLimit

  com.extraData = conf.extraData
  com.gasLimit = conf.gasLimit

  com

# ------------------------------------------------------------------------------
# Public functions, `main()` API
# ------------------------------------------------------------------------------

type StopFuture = Future[void].Raising([CancelledError])

proc runExeClient*(conf: NimbusConf, com: CommonRef, stopper: StopFuture) =
  ## Launches and runs the execution client for pre-configured `nimbus` and
  ## `conf` argument descriptors.
  ##
  info "Launching execution client", version = FullVersionStr, conf

  let nimbus = NimbusNode.init(conf, com)
  defer:
    let
      fc = nimbus.fc
      txFrame = fc.baseTxFrame

    fc.serialize(txFrame).isOkOr:
      error "FC.serialize error: ", msg = error
    txFrame.checkpoint(fc.base.blk.header.number, skipSnapshot = true)
    com.db.persist(txFrame)

  # Be graceful about ctrl-c during init
  if ProcessState.stopping.isNone:
    ProcessState.notifyRunning()

  while true:
    if (let reason = ProcessState.stopping(); reason.isSome()):
      notice "Shutting down", reason = reason[]
      break
    if stopper != nil and stopper.finished():
      break

    chronos.poll()

  # Stop loop
  QuitFailure.onException("Exception while shutting down"):
    waitFor nimbus.closeWait()

# noinline to keep it in stack traces
proc main*() {.noinline.} =
  var config = makeConfig()
  # Set up logging before everything else
  setupLogging(config.logLevel, config.logStdout)
  setupFileLimits()

  ProcessState.setupStopHandlers()

  # TODO provide option for fixing / ignoring permission errors
  if not (checkAndCreateDataDir(config.dataDir)):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  # Metrics are useful not just when running node but also during import
  let metricsServer =
    try:
      waitFor(initMetricsServer(config)).valueOr:
        quit(QuitFailure)
    except CancelledError:
      raiseAssert "Never cancelled"
  defer:
    waitFor metricsServer.stopMetricsServer()

  let
    taskpool = setupTaskpool(config.numThreads)
    com = setupCommonRef(config, taskpool)

  defer:
    com.db.finish()

  case config.cmd
  of NimbusCmd.`import`:
    importBlocks(config, com)
  of NimbusCmd.`import - rlp`:
    try:
      waitFor importRlpBlocks(config, com)
    except CancelledError:
      raiseAssert "Nothing cancels the future"
  else:
    runExeClient(config, com, nil)

when isMainModule:
  main()

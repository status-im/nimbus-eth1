# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  ../execution_chain/compile_info

import
  chronicles,
  eth/net/nat,
  metrics,
  stew/byteutils,
  kzg4844/kzg,
  ./[conf, constants, nimbus_desc, nimbus_import, rpc, version_info],
  ./core/block_import,
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

proc basicServices(nimbus: NimbusNode, config: ExecutionClientConf, com: CommonRef) =
  # Setup the chain
  let fc = ForkedChainRef.init(com,
    eagerStateRoot = config.eagerStateRootCheck,
    persistBatchSize = config.persistBatchSize,
    dynamicBatchSize = config.dynamicBatchSize,
    maxBlobs = config.maxBlobs,
    enableQueue = true)
  if config.deserializeFcState:
    fc.deserialize().isOkOr:
      warn "Loading block DAG from database", msg=error
  else:
    warn "Skipped loading of block DAG from database", deserializeFcState = config.deserializeFcState

  nimbus.fc = fc
  # Setup history expiry and portal

  QuitFailure.onException("Cannot initialise RPC client history"):
    nimbus.fc.portal = HistoryExpiryRef.init(config, com)

  # txPool must be informed of active head
  # so it can know the latest account state
  # e.g. sender nonce, etc
  nimbus.txPool = TxPoolRef.new(nimbus.fc)
  nimbus.beaconEngine = BeaconEngineRef.new(nimbus.txPool)

proc manageAccounts(nimbus: NimbusNode, config: ExecutionClientConf) =
  if config.keyStoreDir.len > 0:
    nimbus.accountsManager[].loadKeystores(config.keyStoreDir).isOkOr:
      fatal "Load keystore error", msg = error
      quit(QuitFailure)

  if string(config.importKey).len > 0:
    nimbus.accountsManager[].importPrivateKey(string config.importKey).isOkOr:
      fatal "Import private key error", msg = error
      quit(QuitFailure)

proc setupP2P(nimbus: NimbusNode, config: ExecutionClientConf, com: CommonRef) =
  ## Creating P2P Server
  let
    keypair = nimbus.rng[].getNetKeys(config.netKey).valueOr:
      fatal "Get network keys error", msg = error
      quit(QuitFailure)
    natId = NimbusName & " " & NimbusVersion
    (extIp, extPorts) = setupAddress(
      config.nat,
      config.listenAddress,
      @[
        (port: config.tcpPort, protocol: PortProtocol.TCP),
        (port: config.udpPort, protocol: PortProtocol.UDP),
      ],
      natId,
    )
    extTcpPort = extPorts[0].toPort()
    extUdpPort = extPorts[1].toPort()

    bootstrapNodes = config.getBootstrapNodes()
    fc = nimbus.fc

  func forkIdProc(): ForkId =
    let header = fc.latestHeader()
    com.forkId(header.number, header.timestamp)

  func compatibleForkIdProc(id: ForkId): bool =
    let header = fc.latestHeader()
    com.compatibleForkId(id, header.number, header.timestamp)

  let forkIdProcs = ForkIdProcs(
    forkId: forkIdProc,
    compatibleForkId: compatibleForkIdProc,
  )

  nimbus.ethNode = newEthereumNode(
    keypair, extIp, extTcpPort, extUdpPort, config.networkId, config.agentString,
    minPeers = config.maxPeers,
    bootstrapNodes = bootstrapNodes,
    bindUdpPort = config.udpPort, bindTcpPort = config.tcpPort,
    bindIp = config.listenAddress,
    rng = nimbus.rng,
    forkIdProcs = forkIdProcs)

  # Add peer service protocol capabilities.
  let doSnapSync = config.snapSyncEnabled or config.snapServerEnabled
  nimbus.ethWire = nimbus.ethNode.addEthHandlerCapability(nimbus.txPool)
  if doSnapSync:
    nimbus.snapWire = nimbus.ethNode.addSnapHandlerCapability()

  # Connect directly to the static nodes
  let staticPeers = config.getStaticPeers()
  if staticPeers.len > 0:
    nimbus.peerManager = PeerManagerRef.new(
      nimbus.ethNode.peerPool,
      config.reconnectInterval,
      config.reconnectMaxRetry,
      staticPeers
    )
    nimbus.peerManager.start()

  # Start Eth node
  if config.maxPeers > 0:
    let discovery = config.getDiscoveryFlags()
    nimbus.ethNode.connectToNetwork(
      enableDiscV4 = DiscoveryType.V4 in discovery,
      enableDiscV5 = DiscoveryType.V5 in discovery,
    )

  # Initalise beacon sync descriptor.
  var syncerShouldRun = (config.maxPeers > 0 or staticPeers.len > 0) and
                        config.engineApiServerEnabled()

  # The beacon sync descriptor might have been pre-allocated with additional
  # features. So do not override.
  if nimbus.beaconSyncRef.isNil:
    nimbus.beaconSyncRef = BeaconSyncRef.init()
  else:
    syncerShouldRun = true

  # Configure beacon syncer.
  nimbus.beaconSyncRef.config(nimbus.ethNode, nimbus.fc, config.maxPeers)

  # Optional for pre-setting the sync target (e.g. for debugging)
  if config.beaconSyncTarget.isSome():
    syncerShouldRun = true
    let
      hex = config.beaconSyncTarget.unsafeGet
      isFinal = config.beaconSyncTargetIsFinal
    if not nimbus.beaconSyncRef.configTarget(hex, isFinal):
      fatal "Error parsing hash32 argument for --debug-beacon-sync-target",
        hash32=hex
      quit QuitFailure

  # Configure snap sync if enabled. When done it will resume beacon sync.
  if config.snapSyncEnabled:
    if nimbus.snapSyncRef.isNil:
      nimbus.snapSyncRef = SnapSyncRef.init()
    else:
      syncerShouldRun = true

    # Configure snap syncer.
    nimbus.snapSyncRef.config(nimbus.ethNode, config.maxPeers)
  else:
    # Disable any external setup unless explicitely activated
    nimbus.snapSyncRef = SnapSyncRef(nil)

  # Deactivating syncer if there is definitely no need to run it. This
  # avoids polling (i.e. waiting for instructions) and some logging.
  if not syncerShouldRun:
    nimbus.beaconSyncRef = BeaconSyncRef(nil)
    nimbus.snapSyncRef = SnapSyncRef(nil)

proc init*(nimbus: NimbusNode, config: ExecutionClientConf, com: CommonRef) =
  nimbus.accountsManager = new AccountsManager
  nimbus.rng = newRng()

  basicServices(nimbus, config, com)
  manageAccounts(nimbus, config)
  setupP2P(nimbus, config, com)
  setupRpc(nimbus, config, com)

  # Not starting any syncer if there is definitely no way to run it. This
  # avoids polling (i.e. waiting for instructions) and some logging.
  block startSyncer:
    if not nimbus.beaconSyncRef.isNil:
      if nimbus.snapSyncRef.isNil:
        # Run full sync by starting beacon sync now.
        if nimbus.beaconSyncRef.start():
          break startSyncer
      else:
        # Start snap sync. When done it will resume beacon sync.
        if nimbus.snapSyncRef.start(nimbus.beaconSyncRef):
          break startSyncer
    nimbus.beaconSyncRef = BeaconSyncRef(nil)
    nimbus.snapSyncRef = SnapSyncRef(nil)

proc init*(T: type NimbusNode, config: ExecutionClientConf, com: CommonRef): T =
  let nimbus = T()
  nimbus.init(config, com)
  nimbus

proc preventLoadingDataDirForTheWrongNetwork(db: CoreDbRef; config: ExecutionClientConf) =
  proc writeDataDirId(kvt: CoreDbTxRef, calculatedId: Hash32) =
    info "Writing data dir ID", ID=calculatedId
    kvt.put(dataDirIdKey().toOpenArray, calculatedId.data).isOkOr:
      fatal "Cannot write data dir ID", ID=calculatedId
      quit(QuitFailure)
    db.persist(kvt)

  let
    kvt = db.baseTxFrame()
    calculatedId = calcHash(config.networkId, config.networkParams)
    dataDirIdBytes = kvt.get(dataDirIdKey().toOpenArray).valueOr:
      # an empty database
      writeDataDirId(kvt, calculatedId)
      return

  if config.rewriteDatadirId:
    writeDataDirId(kvt, calculatedId)
    return

  if calculatedId.data != dataDirIdBytes:
    fatal "Data dir already initialized with other network configuration",
      get=dataDirIdBytes.toHex,
      expected=calculatedId
    quit(QuitFailure)


proc setupCommonRef*(config: ExecutionClientConf): CommonRef =
  let coreDB = AristoDbRocks.newCoreDbRef(
      config.dataDir,
      config.dbOptions(noKeyCache = config.cmd == NimbusCmd.`import`))

  preventLoadingDataDirForTheWrongNetwork(coreDB, config)

  let com = CommonRef.new(
    db = coreDB,
    networkId = config.networkId,
    params = config.networkParams,
    statelessProviderEnabled = config.statelessProviderEnabled,
    statelessWitnessValidation = config.statelessWitnessValidation)

  if config.extraData.len > 32:
    warn "ExtraData exceeds 32 bytes limit, truncate",
      extraData=config.extraData,
      len=config.extraData.len

  if config.gasLimit > GAS_LIMIT_MAXIMUM or
     config.gasLimit < GAS_LIMIT_MINIMUM:
    warn "GasLimit not in expected range, truncate",
      min=GAS_LIMIT_MINIMUM,
      max=GAS_LIMIT_MAXIMUM,
      get=config.gasLimit

  com.extraData = config.extraData
  com.gasLimit = config.gasLimit

  com

# ------------------------------------------------------------------------------
# Public functions, `main()` API
# ------------------------------------------------------------------------------

type StopFuture = Future[void].Raising([CancelledError])

proc runExeClient*(
    config: ExecutionClientConf,
    com: CommonRef,
    stopper: StopFuture,
    nimbus = NimbusNode(nil),
) =
  ## Launches and runs the execution client for pre-configured `nimbus` and
  ## `conf` argument descriptors.
  ##

  var nimbus = nimbus
  if nimbus.isNil:
    nimbus = NimbusNode.init(config, com)
  else:
    nimbus.init(config, com)

  defer:
    let
      fc = nimbus.fc
      txFrame = fc.baseTxFrame

    fc.serialize(txFrame).isOkOr:
      error "FC.serialize error: ", msg = error
    txFrame.checkpoint(fc.base.header.number, skipSnapshot = true)
    com.db.persist(txFrame)

 # Rlp import is there, first load the chain segment
  if config.bootstrapBlocksFile.len > 0:
    try:
      waitFor importRlpBlocks(config, com, nimbus.fc)
    except CancelledError:
      raiseAssert "Nothing cancels the future"
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
proc main*(config = makeConfig(), nimbus = NimbusNode(nil)) {.noinline.} =
  # Set up logging before everything else
  setupLogging(config.logLevel, config.logFormat)
  setupFileLimits()

  info "Launching execution client", version = FullVersionStr, config

  ProcessState.setupStopHandlers()

  # TODO provide option for fixing / ignoring permission errors
  if not (checkAndCreateDataDir(config.dataDir)):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  # Trusted setup is needed for Cancun+ blocks and is shared between threads,
  # so it needs to be initalized from the main thread before anything else tries
  # to use it
  if config.trustedSetupFile.isSome:
    kzg.loadTrustedSetup(config.trustedSetupFile.get(), 0).isOkOr:
      fatal "Cannot load KZG trusted setup from file", msg = error
      quit(QuitFailure)

  # Metrics are useful not just when running node but also during import
  let metricsServer =
    try:
      waitFor(initMetricsServer(config)).valueOr:
        quit(QuitFailure)
    except CancelledError:
      raiseAssert "Never cancelled"
  defer:
    if metricsServer.isSome():
      waitFor metricsServer.stopMetricsServer()

  when compileOption("threads"):
    let
      taskpool = setupTaskpool(config.numThreads)
      com = setupCommonRef(config)
    com.taskpool = taskpool
  else:
    let com = setupCommonRef(config)

  defer:
    com.db.finish()

  case config.cmd
  of NimbusCmd.`import`:
    importBlocks(config, com)
  else:
    runExeClient(config, com, nil, nimbus=nimbus)

when isMainModule:
  main()

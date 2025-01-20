# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ../nimbus/compile_info

import
  std/[os, osproc, strutils, net],
  chronicles,
  eth/net/nat,
  metrics,
  metrics/chronicles_support,
  kzg4844/kzg,
  stew/byteutils,
  ./rpc,
  ./version,
  ./constants,
  ./nimbus_desc,
  ./nimbus_import,
  ./core/block_import,
  ./core/eip4844,
  ./db/core_db/persistent,
  ./db/storage_types,
  ./sync/handlers,
  ./common/chain_config_hash

from beacon_chain/nimbus_binary_common import setupFileLimits

when defined(evmc_enabled):
  import transaction/evmc_dynamic_loader

## TODO:
## * No IPv6 support
## * No multiple bind addresses support
## * No database support

proc basicServices(nimbus: NimbusNode,
                   conf: NimbusConf,
                   com: CommonRef) =
  nimbus.chainRef = ForkedChainRef.init(com)

  # txPool must be informed of active head
  # so it can know the latest account state
  # e.g. sender nonce, etc
  nimbus.txPool = TxPoolRef.new(nimbus.chainRef)
  nimbus.beaconEngine = BeaconEngineRef.new(nimbus.txPool)

proc manageAccounts(nimbus: NimbusNode, conf: NimbusConf) =
  if string(conf.keyStore).len > 0:
    let res = nimbus.ctx.am.loadKeystores(string conf.keyStore)
    if res.isErr:
      fatal "Load keystore error", msg = res.error()
      quit(QuitFailure)

  if string(conf.importKey).len > 0:
    let res = nimbus.ctx.am.importPrivateKey(string conf.importKey)
    if res.isErr:
      fatal "Import private key error", msg = res.error()
      quit(QuitFailure)

proc setupP2P(nimbus: NimbusNode, conf: NimbusConf,
              com: CommonRef) =
  ## Creating P2P Server
  let kpres = nimbus.ctx.getNetKeys(conf.netKey, conf.dataDir.string)
  if kpres.isErr:
    fatal "Get network keys error", msg = kpres.error
    quit(QuitFailure)

  let keypair = kpres.get()
  var address = enode.Address(
    ip: conf.listenAddress,
    tcpPort: conf.tcpPort,
    udpPort: conf.udpPort
  )

  if conf.nat.hasExtIp:
    # any required port redirection is assumed to be done by hand
    address.ip = conf.nat.extIp
  else:
    # automated NAT traversal
    let extIP = getExternalIP(conf.nat.nat)
    # This external IP only appears in the logs, so don't worry about dynamic
    # IPs. Don't remove it either, because the above call does initialisation
    # and discovery for NAT-related objects.
    if extIP.isSome:
      address.ip = extIP.get()
      let extPorts = redirectPorts(tcpPort = address.tcpPort,
                                   udpPort = address.udpPort,
                                   description = NimbusName & " " & NimbusVersion)
      if extPorts.isSome:
        (address.tcpPort, address.udpPort) = extPorts.get()

  let bootstrapNodes = conf.getBootNodes()

  nimbus.ethNode = newEthereumNode(
    keypair, address, conf.networkId, conf.agentString,
    addAllCapabilities = false, minPeers = conf.maxPeers,
    bootstrapNodes = bootstrapNodes,
    bindUdpPort = conf.udpPort, bindTcpPort = conf.tcpPort,
    bindIp = conf.listenAddress,
    rng = nimbus.ctx.rng)

  # Add protocol capabilities
  nimbus.ethNode.addEthHandlerCapability(
    nimbus.ethNode.peerPool, nimbus.chainRef, nimbus.txPool)

  # Always initialise beacon syncer
  nimbus.beaconSyncRef = BeaconSyncRef.init(
    nimbus.ethNode, nimbus.chainRef, conf.maxPeers, conf.beaconChunkSize)

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
    nimbus.networkLoop = nimbus.ethNode.connectToNetwork(
      enableDiscovery = conf.discovery != DiscoveryType.None,
      waitForPeers = true)


proc setupMetrics(nimbus: NimbusNode, conf: NimbusConf) =
  # metrics logging
  if conf.logMetricsEnabled:
    # https://github.com/nim-lang/Nim/issues/17369
    var logMetrics: proc(udata: pointer) {.gcsafe, raises: [].}
    logMetrics = proc(udata: pointer) =
      {.gcsafe.}:
        let registry = defaultRegistry
      info "metrics", registry
      discard setTimer(Moment.fromNow(conf.logMetricsInterval.seconds), logMetrics)
    discard setTimer(Moment.fromNow(conf.logMetricsInterval.seconds), logMetrics)

  # metrics server
  if conf.metricsEnabled:
    info "Starting metrics HTTP server", address = conf.metricsAddress, port = conf.metricsPort
    let res = MetricsHttpServerRef.new($conf.metricsAddress, conf.metricsPort)
    if res.isErr:
      fatal "Failed to create metrics server", msg=res.error
      quit(QuitFailure)

    nimbus.metricsServer = res.get
    waitFor nimbus.metricsServer.start()

proc preventLoadingDataDirForTheWrongNetwork(db: CoreDbRef; conf: NimbusConf) =
  proc writeDataDirId(kvt: CoreDbKvtRef, calculatedId: Hash32) =
    info "Writing data dir ID", ID=calculatedId
    kvt.put(dataDirIdKey().toOpenArray, calculatedId.data).isOkOr:
      fatal "Cannot write data dir ID", ID=calculatedId
      quit(QuitFailure)
      
  let
    kvt = db.ctx.getKvt()
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

proc run(nimbus: NimbusNode, conf: NimbusConf) =
  ## logging
  setLogLevel(conf.logLevel)
  if conf.logFile.isSome:
    let logFile = string conf.logFile.get()
    defaultChroniclesStream.output.outFile = nil # to avoid closing stdout
    discard defaultChroniclesStream.output.open(logFile, fmAppend)

  setupFileLimits()

  info "Launching execution client",
      version = FullVersionStr,
      conf

  when defined(evmc_enabled):
    evmcSetLibraryPath(conf.evm)

  # Trusted setup is needed for processing Cancun+ blocks
  if conf.trustedSetupFile.isSome:
    let fileName = conf.trustedSetupFile.get()
    let res = loadTrustedSetup(fileName, 0)
    if res.isErr:
      fatal "Cannot load Kzg trusted setup from file", msg=res.error
      quit(QuitFailure)
  else:
    let res = loadKzgTrustedSetup()
    if res.isErr:
      fatal "Cannot load baked in Kzg trusted setup", msg=res.error
      quit(QuitFailure)

  createDir(string conf.dataDir)
  let coreDB =
    # Resolve statically for database type
    case conf.chainDbMode:
    of Aristo,AriPrune:
      AristoDbRocks.newCoreDbRef(
        string conf.dataDir,
        conf.dbOptions(noKeyCache = conf.cmd == NimbusCmd.`import`))

  preventLoadingDataDirForTheWrongNetwork(coreDB, conf)
  setupMetrics(nimbus, conf)

  let taskpool =
    try:
      if conf.numThreads < 0:
        fatal "The number of threads --num-threads cannot be negative."
        quit QuitFailure
      elif conf.numThreads == 0:
        Taskpool.new(numThreads = min(countProcessors(), 16))
      else:
        Taskpool.new(numThreads = conf.numThreads)
    except CatchableError as e:
      fatal "Cannot start taskpool", err = e.msg
      quit QuitFailure

  info "Threadpool started", numThreads = taskpool.numThreads

  let com = CommonRef.new(
    db = coreDB,
    taskpool = taskpool,
    pruneHistory = (conf.chainDbMode == AriPrune),
    networkId = conf.networkId,
    params = conf.networkParams)

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

  defer:
    com.db.finish()

  case conf.cmd
  of NimbusCmd.`import`:
    importBlocks(conf, com)
  of NimbusCmd.`import-rlp`:
    importRlpBlocks(conf, com)
  else:
    basicServices(nimbus, conf, com)
    manageAccounts(nimbus, conf)
    setupP2P(nimbus, conf, com)
    setupRpc(nimbus, conf, com)

    if conf.maxPeers > 0 and conf.engineApiServerEnabled():
      # Not starting syncer if there is definitely no way to run it. This
      # avoids polling (i.e. waiting for instructions) and some logging.
      if not nimbus.beaconSyncRef.start():
        nimbus.beaconSyncRef = BeaconSyncRef(nil)

    if nimbus.state == NimbusState.Starting:
      # it might have been set to "Stopping" with Ctrl+C
      nimbus.state = NimbusState.Running

    # Main event loop
    while nimbus.state == NimbusState.Running:
      try:
        poll()
      except CatchableError as e:
        debug "Exception in poll()", exc = e.name, err = e.msg
        discard e # silence warning when chronicles not activated

    # Stop loop
    waitFor nimbus.stop(conf)

when isMainModule:
  var nimbus = NimbusNode(state: NimbusState.Starting, ctx: newEthContext())

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    nimbus.state = NimbusState.Stopping
    echo "\nCtrl+C pressed. Waiting for a graceful shutdown."
  setControlCHook(controlCHandler)

  ## Show logs on stdout until we get the user's logging choice
  discard defaultChroniclesStream.output.open(stdout)

  ## Processing command line arguments
  let conf = makeConfig()

  nimbus.run(conf)

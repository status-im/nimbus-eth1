# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ../nimbus/vm_compile_info

import
  std/[os, strutils, net],
  chronicles,
  eth/keys,
  eth/net/nat,
  metrics,
  metrics/chronicles_support,
  kzg4844/kzg_ex as kzg,
  ./rpc,
  ./version,
  ./constants,
  ./nimbus_desc,
  ./core/eip4844,
  ./core/block_import,
  ./db/core_db/persistent,
  ./sync/protocol,
  ./sync/handlers

when defined(evmc_enabled):
  import transaction/evmc_dynamic_loader

## TODO:
## * No IPv6 support
## * No multiple bind addresses support
## * No database support

proc importBlocks(conf: NimbusConf, com: CommonRef) =
  if string(conf.blocksFile).len > 0:
    # success or not, we quit after importing blocks
    if not importRlpBlock(string conf.blocksFile, com):
      quit(QuitFailure)
    else:
      quit(QuitSuccess)

proc basicServices(nimbus: NimbusNode,
                   conf: NimbusConf,
                   com: CommonRef) =
  nimbus.txPool = TxPoolRef.new(com)

  # txPool must be informed of active head
  # so it can know the latest account state
  # e.g. sender nonce, etc
  let head = com.db.getCanonicalHead()
  doAssert nimbus.txPool.smartHead(head)

  # chainRef: some name to avoid module-name/filed/function misunderstandings
  nimbus.chainRef = newChain(com)
  if conf.verifyFrom.isSome:
    let verifyFrom = conf.verifyFrom.get()
    nimbus.chainRef.extraValidation = 0 < verifyFrom
    nimbus.chainRef.verifyFrom = verifyFrom

  nimbus.chainRef.generateWitness = conf.generateWitness
  nimbus.beaconEngine = BeaconEngineRef.new(nimbus.txPool, nimbus.chainRef)

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
              com: CommonRef, protocols: set[ProtocolFlag]) =
  ## Creating P2P Server
  let kpres = nimbus.ctx.getNetKeys(conf.netKey, conf.dataDir.string)
  if kpres.isErr:
    fatal "Get network keys error", msg = kpres.error
    quit(QuitFailure)

  let keypair = kpres.get()
  var address = Address(
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

  # Add protocol capabilities based on protocol flags
  for w in protocols:
    case w: # handle all possibilities
    of ProtocolFlag.Eth:
      nimbus.ethNode.addEthHandlerCapability(
        nimbus.ethNode.peerPool,
        nimbus.chainRef,
        nimbus.txPool)
    #of ProtocolFlag.Snap:
    #  nimbus.ethNode.addSnapHandlerCapability(
    #    nimbus.ethNode.peerPool,
    #    nimbus.chainRef)
  # Cannot do without minimal `eth` capability
  if ProtocolFlag.Eth notin protocols:
    nimbus.ethNode.addEthHandlerCapability(
      nimbus.ethNode.peerPool,
      nimbus.chainRef)

  # Early-initialise "--snap-sync" before starting any network connections.
  block:
    let
      exCtrlFile = if conf.syncCtrlFile.isNone: none(string)
                   else: some(conf.syncCtrlFile.get)
      tickerOK = conf.logLevel in {
        LogLevel.INFO, LogLevel.DEBUG, LogLevel.TRACE}
    case conf.syncMode:
    of SyncMode.Full:
      nimbus.fullSyncRef = FullSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, conf.maxPeers,
        tickerOK, exCtrlFile)
    #of SyncMode.Snap:
    #  # Minimal capability needed for sync only
    #  if ProtocolFlag.Snap notin protocols:
    #    nimbus.ethNode.addSnapHandlerCapability(
    #      nimbus.ethNode.peerPool)
    #  nimbus.snapSyncRef = SnapSyncRef.init(
    #    nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, conf.maxPeers,
    #    tickerOK, exCtrlFile)
    of SyncMode.Default:
      if com.forkGTE(MergeFork):
        nimbus.beaconSyncRef = BeaconSyncRef.init(
          nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, conf.maxPeers,
        )
      else:
        nimbus.fullSyncRef = FullSyncRef.init(
          nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, conf.maxPeers,
          tickerOK, exCtrlFile)

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
    var waitForPeers = true
    case conf.syncMode:
    #of SyncMode.Snap:
    #  waitForPeers = false
    of SyncMode.Full, SyncMode.Default:
      discard
    nimbus.networkLoop = nimbus.ethNode.connectToNetwork(
      enableDiscovery = conf.discovery != DiscoveryType.None,
      waitForPeers = waitForPeers)


proc localServices(nimbus: NimbusNode, conf: NimbusConf,
                   com: CommonRef, protocols: set[ProtocolFlag]) =
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

  nimbus.setupRpc(conf, com, protocols)

  # metrics server
  if conf.metricsEnabled:
    info "Starting metrics HTTP server", address = conf.metricsAddress, port = conf.metricsPort
    let res = MetricsHttpServerRef.new($conf.metricsAddress, conf.metricsPort)
    if res.isErr:
      fatal "Failed to create metrics server", msg=res.error
      quit(QuitFailure)

    nimbus.metricsServer = res.get
    waitFor nimbus.metricsServer.start()

proc start(nimbus: NimbusNode, conf: NimbusConf) =
  ## logging
  setLogLevel(conf.logLevel)
  if conf.logFile.isSome:
    let logFile = string conf.logFile.get()
    defaultChroniclesStream.output.outFile = nil # to avoid closing stdout
    discard defaultChroniclesStream.output.open(logFile, fmAppend)

  when defined(evmc_enabled):
    evmcSetLibraryPath(conf.evm)

  createDir(string conf.dataDir)
  let coreDB =
    # Resolve statically for database type
    case conf.chainDbMode:
    of Aristo,AriPrune:
      AristoDbRocks.newCoreDbRef(string conf.dataDir)
  let com = CommonRef.new(
    db = coreDB,
    pruneHistory = (conf.chainDbMode == AriPrune),
    networkId = conf.networkId,
    params = conf.networkParams)

  com.initializeEmptyDb()

  let protocols = conf.getProtocolFlags()

  if conf.cmd != NimbusCmd.`import` and conf.trustedSetupFile.isSome:
    let fileName = conf.trustedSetupFile.get()
    let res = Kzg.loadTrustedSetup(fileName)
    if res.isErr:
      fatal "Cannot load Kzg trusted setup from file", msg=res.error
      quit(QuitFailure)
  else:
    let res = loadKzgTrustedSetup()
    if res.isErr:
      fatal "Cannot load baked in Kzg trusted setup", msg=res.error
      quit(QuitFailure)

  case conf.cmd
  of NimbusCmd.`import`:
    importBlocks(conf, com)
  else:
    basicServices(nimbus, conf, com)
    manageAccounts(nimbus, conf)
    setupP2P(nimbus, conf, com, protocols)
    localServices(nimbus, conf, com, protocols)

    if conf.maxPeers > 0:
      case conf.syncMode:
      of SyncMode.Default:
        if com.forkGTE(MergeFork):
          nimbus.beaconSyncRef.start
        else:
          nimbus.fullSyncRef.start
      of SyncMode.Full:
        nimbus.fullSyncRef.start
      #of SyncMode.Snap:
      #  nimbus.snapSyncRef.start

    if nimbus.state == NimbusState.Starting:
      # it might have been set to "Stopping" with Ctrl+C
      nimbus.state = NimbusState.Running

proc process*(nimbus: NimbusNode, conf: NimbusConf) =
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

  nimbus.start(conf)
  nimbus.process(conf)

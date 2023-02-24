# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ../nimbus/vm_compile_info

import
  std/[os, net],
  chronicles,
  chronos,
  eth/[keys, net/nat],
  eth/p2p as eth_p2p,
  json_rpc/rpcserver,
  metrics,
  metrics/[chronos_httpserver],
  stew/shims/net as stewNet,
  websock/websock as ws,
  "."/[config, constants, version, common],
  ./db/select_backend,
  ./graphql/ethapi,
  ./core/[chain, sealer, tx_pool],
  ./rpc/merge/merger,
  ./sync/[legacy, full, protocol, snap,
    protocol/les_protocol, handlers, peers]

when defined(evmc_enabled):
  import transaction/evmc_dynamic_loader

## TODO:
## * No IPv6 support
## * No multiple bind addresses support
## * No database support

type
  NimbusState = enum
    Starting, Running, Stopping

  NimbusNode = ref object
    ethNode: EthereumNode
    state: NimbusState
    sealingEngine: SealingEngineRef
    ctx: EthContext
    chainRef: ChainRef
    txPool: TxPoolRef
    networkLoop: Future[void]
    dbBackend: ChainDB
    peerManager: PeerManagerRef
    legaSyncRef: LegacySyncRef
    snapSyncRef: SnapSyncRef
    fullSyncRef: FullSyncRef
    merger: MergerRef

proc basicServices(nimbus: NimbusNode,
                   conf: NimbusConf,
                   com: CommonRef) =
  # app wide TxPool singleton
  # TODO: disable some of txPool internal mechanism if
  # the engineSigner is zero.
  nimbus.txPool = TxPoolRef.new(com, conf.engineSigner)

  # chainRef: some name to avoid module-name/filed/function misunderstandings
  nimbus.chainRef = newChain(com)
  if conf.verifyFrom.isSome:
    let verifyFrom = conf.verifyFrom.get()
    nimbus.chainRef.extraValidation = 0 < verifyFrom
    nimbus.chainRef.verifyFrom = verifyFrom

  # this is temporary workaround to track POS transition
  # until we have proper chain config and hard fork module
  # see issue #640
  nimbus.merger = MergerRef.new(com.db)

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
              protocols: set[ProtocolFlag]) =
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
    of ProtocolFlag.Les:
      nimbus.ethNode.addCapability les
    of ProtocolFlag.Snap:
      nimbus.ethNode.addSnapHandlerCapability(
        nimbus.ethNode.peerPool,
        nimbus.chainRef)

  # Early-initialise "--snap-sync" before starting any network connections.
  block:
    let tickerOK =
      conf.logLevel in {LogLevel.INFO, LogLevel.DEBUG, LogLevel.TRACE}
    # Minimal capability needed for sync only
    if ProtocolFlag.Eth notin protocols:
      nimbus.ethNode.addEthHandlerCapability(
        nimbus.ethNode.peerPool,
        nimbus.chainRef)
    case conf.syncMode:
    of SyncMode.Full:
      nimbus.fullSyncRef = FullSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, conf.maxPeers,
        tickerOK)
    of SyncMode.Snap, SyncMode.SnapCtx:
      # Minimal capability needed for sync only
      if ProtocolFlag.Snap notin protocols:
        nimbus.ethNode.addSnapHandlerCapability(
          nimbus.ethNode.peerPool)
      nimbus.snapSyncRef = SnapSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, conf.maxPeers,
        nimbus.dbBackend, tickerOK, noRecovery = (conf.syncMode==SyncMode.Snap))
    of SyncMode.Default:
      nimbus.legaSyncRef = LegacySyncRef.new(
        nimbus.ethNode, nimbus.chainRef)

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
    of SyncMode.Snap, SyncMode.SnapCtx:
      waitForPeers = false
    of SyncMode.Full, SyncMode.Default:
      discard
    nimbus.networkLoop = nimbus.ethNode.connectToNetwork(
      enableDiscovery = conf.discovery != DiscoveryType.None,
      waitForPeers = waitForPeers)

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
  nimbus.dbBackend = newChainDB(string conf.dataDir)
  let trieDB = trieDB nimbus.dbBackend
  let com = CommonRef.new(trieDB,
    conf.pruneMode == PruneMode.Full,
    conf.networkId,
    conf.networkParams
    )

  com.initializeEmptyDb()
  let protocols = conf.getProtocolFlags()

  block:
    basicServices(nimbus, conf, com)
    manageAccounts(nimbus, conf)
    setupP2P(nimbus, conf, protocols)
    #localServices(nimbus, conf, com, protocols)

    if conf.maxPeers > 0:
      case conf.syncMode:
      of SyncMode.Default:
        nimbus.legaSyncRef.start
        nimbus.ethNode.setEthHandlerNewBlocksAndHashes(
          legacy.newBlockHandler,
          legacy.newBlockHashesHandler,
          cast[pointer](nimbus.legaSyncRef))
      of SyncMode.Full:
        nimbus.fullSyncRef.start
      of SyncMode.Snap, SyncMode.SnapCtx:
        nimbus.snapSyncRef.start

    if nimbus.state == Starting:
      # it might have been set to "Stopping" with Ctrl+C
      nimbus.state = Running

proc stop*(nimbus: NimbusNode, conf: NimbusConf) {.async, gcsafe.} =
  trace "Graceful shutdown"
  if conf.engineSigner != ZERO_ADDRESS:
    await nimbus.sealingEngine.stop()
  if conf.maxPeers > 0:
    await nimbus.networkLoop.cancelAndWait()
  if nimbus.peerManager.isNil.not:
    await nimbus.peerManager.stop()
  if nimbus.snapSyncRef.isNil.not:
    nimbus.snapSyncRef.stop()
  if nimbus.fullSyncRef.isNil.not:
    nimbus.fullSyncRef.stop()

proc process*(nimbus: NimbusNode, conf: NimbusConf) =
  # Main event loop
  while nimbus.state == Running:
    try:
      poll()
    except CatchableError as e:
      debug "Exception in poll()", exc = e.name, err = e.msg
      discard e # silence warning when chronicles not activated

  # Stop loop
  waitFor nimbus.stop(conf)

when isMainModule:
  var nimbus = NimbusNode(state: Starting, ctx: newEthContext())

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    nimbus.state = Stopping
    echo "\nCtrl+C pressed. Waiting for a graceful shutdown."
  setControlCHook(controlCHandler)

  ## Show logs on stdout until we get the user's logging choice
  discard defaultChroniclesStream.output.open(stdout)

  ## Processing command line arguments
  let conf = makeConfig()

  nimbus.start(conf)
  nimbus.process(conf)

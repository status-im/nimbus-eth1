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
  eth/keys,
  eth/p2p as eth_p2p,
  json_rpc/rpcserver,
  metrics,
  metrics/[chronos_httpserver],
  stew/shims/net as stewNet,
  "."/[config, constants, common],
  ./db/select_backend,
  ./core/[chain, tx_pool],
  ./rpc/merge/merger,
  ./sync/[legacy, full, protocol, snap, handlers, peers]

type
  NimbusState = enum
    Starting, Running, Stopping

  NimbusNode = ref object
    ethNode: EthereumNode
    state: NimbusState
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

const
  MAX_PEERS = 25
let
  DATA_DIR = getHomeDir() / ".cache" / "nimbus"

proc basicServices(nimbus: NimbusNode,
                   com: CommonRef) =
  # app wide TxPool singleton
  # TODO: disable some of txPool internal mechanism if
  # the engineSigner is zero.
  nimbus.txPool = TxPoolRef.new(com, ZERO_ADDRESS)

  # chainRef: some name to avoid module-name/filed/function misunderstandings
  nimbus.chainRef = newChain(com)

  # this is temporary workaround to track POS transition
  # until we have proper chain config and hard fork module
  # see issue #640
  nimbus.merger = MergerRef.new(com.db)

proc setupP2P(nimbus: NimbusNode, conf: NimbusConf,
              protocols: set[ProtocolFlag]) =
  ## Creating P2P Server
  let kpres = nimbus.ctx.getNetKeys("random", DATA_DIR)
  if kpres.isErr:
    fatal "Get network keys error", msg = kpres.error
    quit(QuitFailure)

  let keypair = kpres.get()
  var address = Address(
    ip: ValidIpAddress.init("0.0.0.0"),
    tcpPort: Port(30303),
    udpPort: Port(30303)
  )

  let bootstrapNodes = conf.getBootNodes()

  nimbus.ethNode = newEthereumNode(
    keypair, address, conf.networkId, conf.agentString,
    addAllCapabilities = false, minPeers = MAX_PEERS,
    bootstrapNodes = bootstrapNodes,
    bindUdpPort = conf.udpPort, bindTcpPort = conf.tcpPort,
    bindIp =  ValidIpAddress.init("0.0.0.0"),
    rng = nimbus.ctx.rng)

  # Add protocol capabilities based on protocol flags
  block:
    block:
      nimbus.ethNode.addEthHandlerCapability(
        nimbus.ethNode.peerPool,
        nimbus.chainRef,
        nimbus.txPool)

  # Early-initialise "--snap-sync" before starting any network connections.
  block:
    let tickerOK = true
    # Minimal capability needed for sync only
    if ProtocolFlag.Eth notin protocols:
      nimbus.ethNode.addEthHandlerCapability(
        nimbus.ethNode.peerPool,
        nimbus.chainRef)
    let syncMode = SyncMode.Full
    case syncMode:
    of SyncMode.Full:
      nimbus.fullSyncRef = FullSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, MAX_PEERS,
        tickerOK)
    of SyncMode.Snap, SyncMode.SnapCtx:
      # Minimal capability needed for sync only
      if ProtocolFlag.Snap notin protocols:
        nimbus.ethNode.addSnapHandlerCapability(
          nimbus.ethNode.peerPool)
      nimbus.snapSyncRef = SnapSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, MAX_PEERS,
        nimbus.dbBackend, tickerOK, noRecovery = false)
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
  block:
    var waitForPeers = true
    nimbus.networkLoop = nimbus.ethNode.connectToNetwork(
      enableDiscovery = false,
      waitForPeers = true)

proc start(nimbus: NimbusNode, conf: NimbusConf) =
  ## logging
  setLogLevel(conf.logLevel)
  if conf.logFile.isSome:
    let logFile = string conf.logFile.get()
    defaultChroniclesStream.output.outFile = nil # to avoid closing stdout
    discard defaultChroniclesStream.output.open(logFile, fmAppend)

  createDir(DATA_DIR)
  nimbus.dbBackend = newChainDB(DATA_DIR)
  let trieDB = trieDB nimbus.dbBackend
  let com = CommonRef.new(trieDB,
    true, # conf.pruneMode == PruneMode.Full,
    conf.networkId,
    conf.networkParams
    )

  com.initializeEmptyDb()
  let protocols = conf.getProtocolFlags()

  block:
    basicServices(nimbus, com)
    setupP2P(nimbus, conf, protocols)

    block:
      let syncMode = SyncMode.Full
      case syncMode:
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

proc stop*(nimbus: NimbusNode) {.async, gcsafe.} =
  trace "Graceful shutdown"
  block:
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
  waitFor nimbus.stop()

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

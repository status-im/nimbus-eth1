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
  eth/[keys, p2p/bootnodes],
  eth/p2p as eth_p2p,
  stew/shims/net as stewNet,
  "."/[constants, common],
  ./db/select_backend,
  ./core/[chain, tx_pool],
  ./sync/[legacy, full, protocol, snap, handlers]

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
    legaSyncRef: LegacySyncRef
    snapSyncRef: SnapSyncRef
    fullSyncRef: FullSyncRef

  NimbusSyncMode = enum
    SyncModeDefault
    SyncModeFull
    SyncModeSnap
    SyncModeSnapCtx

const
  CONFIG_MAX_PEERS = 25
  CONFIG_AGENT_STRING = "Wen dowego afoot tomann abode stomen forest cooryin"
  CONFIG_LOG_LEVEL = LogLevel.INFO
  CONFIG_SYNC_MODE = SyncModeFull
let
  CONFIG_DATA_DIR = getHomeDir() / ".cache" / "nimbus"

proc basicServices(nimbus: NimbusNode,
                   com: CommonRef) =
  # app wide TxPool singleton
  # TODO: disable some of txPool internal mechanism if
  # the engineSigner is zero.
  nimbus.txPool = TxPoolRef.new(com, ZERO_ADDRESS)

  # chainRef: some name to avoid module-name/filed/function misunderstandings
  nimbus.chainRef = newChain(com)

proc setupP2P(nimbus: NimbusNode) =
  ## Creating P2P Server
  let kpres = nimbus.ctx.getNetKeys("random", CONFIG_DATA_DIR)
  if kpres.isErr:
    fatal "Get network keys error", msg = kpres.error
    quit(QuitFailure)

  let keypair = kpres.get()
  var address = Address(
    ip: ValidIpAddress.init("0.0.0.0"),
    tcpPort: Port(30303),
    udpPort: Port(30303)
  )

  var bootstrapNodes: seq[ENode]
  for item in MainnetBootnodes:
    bootstrapNodes.add ENode.fromString(item).tryGet()

  nimbus.ethNode = newEthereumNode(
    keypair, address, MainNet, CONFIG_AGENT_STRING,
    addAllCapabilities = false, minPeers = CONFIG_MAX_PEERS,
    bootstrapNodes = bootstrapNodes,
    bindUdpPort = Port(30303), bindTcpPort = Port(30303),
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
    case CONFIG_SYNC_MODE:
    of SyncModeFull:
      nimbus.fullSyncRef = FullSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, CONFIG_MAX_PEERS,
        true)
    of SyncModeSnap, SyncModeSnapCtx:
      # Minimal capability needed for sync only
      block:
        nimbus.ethNode.addSnapHandlerCapability(
          nimbus.ethNode.peerPool)
      nimbus.snapSyncRef = SnapSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, CONFIG_MAX_PEERS,
        nimbus.dbBackend, true, noRecovery = false)
    of SyncModeDefault:
      nimbus.legaSyncRef = LegacySyncRef.new(
        nimbus.ethNode, nimbus.chainRef)

  # Start Eth node
  block:
    nimbus.networkLoop = nimbus.ethNode.connectToNetwork(
      enableDiscovery = false,
      waitForPeers = true)

proc start(nimbus: NimbusNode) =
  ## logging
  setLogLevel(CONFIG_LOG_LEVEL)

  createDir(CONFIG_DATA_DIR)
  nimbus.dbBackend = newChainDB(CONFIG_DATA_DIR)
  let trieDB = trieDB nimbus.dbBackend
  let com = CommonRef.new(trieDB,
    true,
    MainNet,
    MainNet.networkParams
    )

  com.initializeEmptyDb()

  block:
    basicServices(nimbus, com)
    setupP2P(nimbus)

    block:
      case CONFIG_SYNC_MODE:
      of SyncModeDefault:
        nimbus.legaSyncRef.start
        nimbus.ethNode.setEthHandlerNewBlocksAndHashes(
          legacy.newBlockHandler,
          legacy.newBlockHashesHandler,
          cast[pointer](nimbus.legaSyncRef))
      of SyncModeFull:
        nimbus.fullSyncRef.start
      of SyncModeSnap, SyncModeSnapCtx:
        nimbus.snapSyncRef.start

    if nimbus.state == Starting:
      # it might have been set to "Stopping" with Ctrl+C
      nimbus.state = Running

proc stop*(nimbus: NimbusNode) {.async, gcsafe.} =
  trace "Graceful shutdown"
  block:
    await nimbus.networkLoop.cancelAndWait()
  if nimbus.snapSyncRef.isNil.not:
    nimbus.snapSyncRef.stop()
  if nimbus.fullSyncRef.isNil.not:
    nimbus.fullSyncRef.stop()

proc process*(nimbus: NimbusNode) =
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

  echo "*** gabbleblotchit: Ignoring command line arguments"
  nimbus.start()
  nimbus.process()

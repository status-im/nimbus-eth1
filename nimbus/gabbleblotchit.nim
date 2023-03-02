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

when defined(swap_sync_refs):
  {.warning: "Swapped positions of snapSyncRef and fullSyncRef".}

import
  std/[os, net],
  chronicles,
  chronos,
  eth/[keys, p2p/bootnodes],
  eth/p2p as eth_p2p,
  stew/shims/net as stewNet,
  ./common,
  ./db/select_backend,
  ./core/chain,
  ./sync/[full, protocol, snap]

type
  NimbusState = enum
    Starting, Running, Stopping

  NimbusNode = ref object
    ethNode: EthereumNode
    state: NimbusState
    ctx: EthContext
    chainRef: ChainRef
    dbBackend: ChainDB
    when defined(swap_sync_refs):
      fullSyncRef: FullSyncRef
      snapSyncRef: SnapSyncRef
    else:
      snapSyncRef: SnapSyncRef # << reverse these two and the systems ..
      fullSyncRef: FullSyncRef # << .. survives without crashing

const
  CONFIG_MAX_PEERS = 25
  CONFIG_AGENT_STRING = "Wen dowego afoot tomann abode stomen forest cooryin"
  CONFIG_LOG_LEVEL = LogLevel.INFO
let
  CONFIG_DATA_DIR = getHomeDir() / ".cache" / "nimbus"

proc basicServices(nimbus: NimbusNode,
                   com: CommonRef) =
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

  # Early-initialise "--snap-sync" before starting any network connections.
  block:
    block:
      nimbus.fullSyncRef = FullSyncRef.init(
        nimbus.ethNode, nimbus.chainRef, nimbus.ctx.rng, CONFIG_MAX_PEERS,
        true)

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
      block:
        nimbus.fullSyncRef.start

    if nimbus.state == Starting:
      # it might have been set to "Stopping" with Ctrl+C
      nimbus.state = Running

proc stop*(nimbus: NimbusNode) {.async, gcsafe.} =
  trace "Graceful shutdown"
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

  GC_fullCollect() # make sure that gcc/asan does not crash the gc

  var info = ""
  when defined(boehmgc):
    info = "Boehm gc debugging"
  elif defined(release):
    info = "Release mode"
  else:
    info = "Gc debugging"
  when defined(swap_sync_refs):
    info &= ", swapped sync descriptors"
  echo "*** gabbleblotchit: ", info

  nimbus.start()
  nimbus.process()

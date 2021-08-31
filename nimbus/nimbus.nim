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
  os, strutils, net, options,
  eth/keys, db/[storage_types, db_chain, select_backend],
  eth/common as eth_common, eth/p2p as eth_p2p,
  chronos, json_rpc/rpcserver, chronicles,
  eth/p2p/rlpx_protocols/les_protocol,
  ./p2p/blockchain_sync, eth/net/nat, eth/p2p/peer_pool,
  ./sync/protocol_eth65,
  config, genesis, rpc/[common, p2p, debug], p2p/chain,
  eth/trie/db, metrics, metrics/[chronos_httpserver, chronicles_support],
  graphql/ethapi,
  "."/[utils, conf_utils, sealer, constants]

## TODO:
## * No IPv6 support
## * No multiple bind addresses support
## * No database support

const
  nimbusClientId = "nimbus 0.1.0"

type
  NimbusState = enum
    Starting, Running, Stopping

  NimbusNode = ref object
    rpcServer*: RpcHttpServer
    ethNode*: EthereumNode
    state*: NimbusState
    graphqlServer*: GraphqlHttpServerRef
    wsRpcServer*: RpcWebSocketServer
    sealingEngine*: SealingEngineRef

proc start(nimbus: NimbusNode) =
  var conf = getConfiguration()

  ## logging
  setLogLevel(conf.debug.logLevel)
  if len(conf.debug.logFile) != 0:
    defaultChroniclesStream.output.outFile = nil # to avoid closing stdout
    discard defaultChroniclesStream.output.open(conf.debug.logFile, fmAppend)

  createDir(conf.dataDir)
  let trieDB = trieDB newChainDb(conf.dataDir)
  var chainDB = newBaseChainDB(trieDB,
    conf.prune == PruneMode.Full,
    conf.net.networkId
    )
  chainDB.populateProgress()

  if canonicalHeadHashKey().toOpenArray notin trieDB:
    initializeEmptyDb(chainDb)
    doAssert(canonicalHeadHashKey().toOpenArray in trieDB)

  if conf.importFile.len > 0:
    # success or not, we quit after importing blocks
    if not importRlpBlock(conf.importFile, chainDB):
      quit(QuitFailure)
    else:
      quit(QuitSuccess)

  let res = conf.loadKeystoreFiles()
  if res.isErr:
    echo res.error()
    quit(QuitFailure)

  # metrics logging
  if conf.debug.logMetrics:
    # https://github.com/nim-lang/Nim/issues/17369
    var logMetrics: proc(udata: pointer) {.gcsafe, raises: [Defect].}
    logMetrics = proc(udata: pointer) =
      {.gcsafe.}:
        let registry = defaultRegistry
      info "metrics", registry
      discard setTimer(Moment.fromNow(conf.debug.logMetricsInterval.seconds), logMetrics)
    discard setTimer(Moment.fromNow(conf.debug.logMetricsInterval.seconds), logMetrics)

  ## Creating P2P Server
  let keypair = conf.net.nodekey.toKeyPair()

  var address: Address
  address.ip = parseIpAddress("0.0.0.0")
  address.tcpPort = Port(conf.net.bindPort)
  address.udpPort = Port(conf.net.discPort)
  if conf.net.nat == NatNone:
    if conf.net.externalIP != "":
      # any required port redirection is assumed to be done by hand
      address.ip = parseIpAddress(conf.net.externalIP)
  else:
    # automated NAT traversal
    let extIP = getExternalIP(conf.net.nat)
    # This external IP only appears in the logs, so don't worry about dynamic
    # IPs. Don't remove it either, because the above call does initialisation
    # and discovery for NAT-related objects.
    if extIP.isSome:
      address.ip = extIP.get()
      let extPorts = redirectPorts(tcpPort = address.tcpPort,
                                    udpPort = address.udpPort,
                                    description = NIMBUS_NAME & " " & NIMBUS_VERSION)
      if extPorts.isSome:
        (address.tcpPort, address.udpPort) = extPorts.get()

  nimbus.ethNode = newEthereumNode(keypair, address, conf.net.networkId,
                                   nil, nimbusClientId,
                                   addAllCapabilities = false,
                                   minPeers = conf.net.maxPeers)
  # Add protocol capabilities based on protocol flags
  if ProtocolFlags.Eth in conf.net.protocols:
    nimbus.ethNode.addCapability eth
  if ProtocolFlags.Les in conf.net.protocols:
    nimbus.ethNode.addCapability les

  # chainRef: some name to avoid module-name/filed/function misunderstandings
  let chainRef = newChain(chainDB)
  nimbus.ethNode.chain = chainRef
  if conf.verifyFromOk:
    chainRef.extraValidation = 0 < conf.verifyFrom
    chainRef.verifyFrom = conf.verifyFrom

  ## Creating RPC Server
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer = newRpcHttpServer(conf.rpc.binds)
    setupCommonRpc(nimbus.ethNode, nimbus.rpcServer)

  # Enable RPC APIs based on RPC flags and protocol flags
  if RpcFlags.Eth in conf.rpc.flags and ProtocolFlags.Eth in conf.net.protocols:
    setupEthRpc(nimbus.ethNode, chainDB, nimbus.rpcServer)
  if RpcFlags.Debug in conf.rpc.flags:
    setupDebugRpc(chainDB, nimbus.rpcServer)

  # Creating Websocket RPC Server
  if RpcFlags.Enabled in conf.ws.flags:
    doAssert(conf.ws.binds.len > 0)
    nimbus.wsRpcServer = newRpcWebSocketServer(conf.ws.binds[0])
    setupCommonRpc(nimbus.ethNode, nimbus.wsRpcServer)

  # Enable Websocket RPC APIs based on RPC flags and protocol flags
  if RpcFlags.Eth in conf.ws.flags and ProtocolFlags.Eth in conf.net.protocols:
    setupEthRpc(nimbus.ethNode, chainDB, nimbus.wsRpcServer)
  if RpcFlags.Debug in conf.ws.flags:
    setupDebugRpc(chainDB, nimbus.wsRpcServer)

  ## Starting servers
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer.rpc("admin_quit") do() -> string:
      {.gcsafe.}:
        nimbus.state = Stopping
      result = "EXITING"
    nimbus.rpcServer.start()

  if conf.graphql.enabled:
    nimbus.graphqlServer = setupGraphqlHttpServer(conf, chainDB, nimbus.ethNode)
    nimbus.graphqlServer.start()

  if conf.engineSigner != ZERO_ADDRESS:
    let rs = validateSealer(chainRef)
    if rs.isErr:
      echo rs.error
      quit(QuitFailure)
    nimbus.sealingEngine = SealingEngineRef.new(chainRef)
    nimbus.sealingEngine.start()

  # metrics server
  if conf.net.metricsServer:
    let metricsAddress = "127.0.0.1"
    info "Starting metrics HTTP server", address = metricsAddress, port = conf.net.metricsServerPort
    startMetricsHttpServer(metricsAddress, Port(conf.net.metricsServerPort))

  # Connect directly to the static nodes
  for enode in conf.net.staticNodes:
    asyncCheck nimbus.ethNode.peerPool.connectToNode(newNode(enode))

  # Connect via discovery
  if conf.net.customBootNodes.len > 0:
    # override the default bootnodes from public network
    waitFor nimbus.ethNode.connectToNetwork(conf.net.customBootNodes,
      enableDiscovery = NoDiscover notin conf.net.flags)
  else:
    waitFor nimbus.ethNode.connectToNetwork(conf.net.bootNodes,
      enableDiscovery = NoDiscover notin conf.net.flags)

  if ProtocolFlags.Eth in conf.net.protocols:
    # TODO: temp code until the CLI/RPC interface is fleshed out
    let status = waitFor nimbus.ethNode.fastBlockchainSync()
    if status != syncSuccess:
      debug "Block sync failed: ", status

  if nimbus.state == Starting:
    # it might have been set to "Stopping" with Ctrl+C
    nimbus.state = Running

proc stop*(nimbus: NimbusNode) {.async, gcsafe.} =
  trace "Graceful shutdown"
  var conf = getConfiguration()
  if RpcFlags.Enabled in conf.rpc.flags:
    nimbus.rpcServer.stop()
  if conf.graphql.enabled:
    await nimbus.graphqlServer.stop()
  if conf.engineSigner != ZERO_ADDRESS:
    await nimbus.sealingEngine.stop()

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
  var nimbus = NimbusNode(state: Starting)

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    nimbus.state = Stopping
    echo "\nCtrl+C pressed. Waiting for a graceful shutdown."
  setControlCHook(controlCHandler)

  var message: string

  ## Print Nimbus header
  echo NimbusHeader

  ## Show logs on stdout until we get the user's logging choice
  discard defaultChroniclesStream.output.open(stdout)

  ## Processing command line arguments
  if processArguments(message) != ConfigStatus.Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  nimbus.start()
  nimbus.process()


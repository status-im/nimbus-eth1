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
  std/[os, strutils, net, options],
  chronicles,
  chronos,
  eth/[keys, net/nat, trie/db],
  eth/common as eth_common,
  eth/p2p as eth_p2p,
  eth/p2p/[peer_pool, rlpx_protocols/les_protocol],
  json_rpc/rpcserver,
  metrics,
  metrics/[chronos_httpserver, chronicles_support],
  stew/shims/net as stewNet,
  websock/types as ws,
  "."/[conf_utils, config, constants, context, genesis, sealer, utils, version],
  ./db/[storage_types, db_chain, select_backend],
  ./graphql/ethapi,
  ./p2p/[chain, clique/clique_desc, clique/clique_sealer],
  ./rpc/[common, debug, engine_api, jwt_auth, p2p, cors],
  ./sync/[fast, full, protocol, snap],
  ./utils/tx_pool

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
    rpcServer: RpcHttpServer
    engineApiServer: RpcHttpServer
    engineApiWsServer: RpcWebSocketServer
    ethNode: EthereumNode
    state: NimbusState
    graphqlServer: GraphqlHttpServerRef
    wsRpcServer: RpcWebSocketServer
    sealingEngine: SealingEngineRef
    ctx: EthContext
    chainRef: Chain
    txPool: TxPoolRef
    networkLoop: Future[void]

proc importBlocks(conf: NimbusConf, chainDB: BaseChainDB) =
  if string(conf.blocksFile).len > 0:
    # success or not, we quit after importing blocks
    if not importRlpBlock(string conf.blocksFile, chainDB):
      quit(QuitFailure)
    else:
      quit(QuitSuccess)

proc manageAccounts(nimbus: NimbusNode, conf: NimbusConf) =
  if string(conf.keyStore).len > 0:
    let res = nimbus.ctx.am.loadKeystores(string conf.keyStore)
    if res.isErr:
      echo res.error()
      quit(QuitFailure)

  if string(conf.importKey).len > 0:
    let res = nimbus.ctx.am.importPrivateKey(string conf.importKey)
    if res.isErr:
      echo res.error()
      quit(QuitFailure)

proc setupP2P(nimbus: NimbusNode, conf: NimbusConf,
              chainDB: BaseChainDB, protocols: set[ProtocolFlag]) =
  ## Creating P2P Server
  let kpres = nimbus.ctx.hexToKeyPair(conf.nodeKeyHex)
  if kpres.isErr:
    echo kpres.error()
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
    keypair, address, conf.networkId, nil, conf.agentString,
    addAllCapabilities = false, minPeers = conf.maxPeers,
    bootstrapNodes = bootstrapNodes,
    bindUdpPort = conf.udpPort, bindTcpPort = conf.tcpPort,
    bindIp = conf.listenAddress)

  # Add protocol capabilities based on protocol flags
  if ProtocolFlag.Eth in protocols:
    nimbus.ethNode.addCapability protocol.eth
    case conf.syncMode:
    of SyncMode.Snap:
      nimbus.ethNode.addCapability protocol.snap
    of SyncMode.Full, SyncMode.Default:
      discard

  if ProtocolFlag.Les in protocols:
    nimbus.ethNode.addCapability les

  # chainRef: some name to avoid module-name/filed/function misunderstandings
  nimbus.chainRef = newChain(chainDB)
  nimbus.ethNode.chain = nimbus.chainRef
  if conf.verifyFrom.isSome:
    let verifyFrom = conf.verifyFrom.get()
    nimbus.chainRef.extraValidation = 0 < verifyFrom
    nimbus.chainRef.verifyFrom = verifyFrom

  # Early-initialise "--snap-sync" before starting any network connections.
  if ProtocolFlag.Eth in protocols:
    let tickerOK =
      conf.logLevel in {LogLevel.INFO, LogLevel.DEBUG, LogLevel.TRACE}
    case conf.syncMode:
    of SyncMode.Full:
      FullSyncRef.init(nimbus.ethNode, conf.maxPeers, tickerOK).start
    of SyncMode.Snap:
      SnapSyncRef.init(nimbus.ethNode, conf.maxPeers).start
    of SyncMode.Default:
      discard

  # Connect directly to the static nodes
  let staticPeers = conf.getStaticPeers()
  for enode in staticPeers:
    asyncSpawn nimbus.ethNode.peerPool.connectToNode(newNode(enode))

  # Start Eth node
  if conf.maxPeers > 0:
    var waitForPeers = true
    case conf.syncMode:
    of SyncMode.Snap:
      waitForPeers = false
    of SyncMode.Full, SyncMode.Default:
      discard
    nimbus.networkLoop = nimbus.ethNode.connectToNetwork(
      enableDiscovery = conf.discovery != DiscoveryType.None,
      waitForPeers = waitForPeers)

proc localServices(nimbus: NimbusNode, conf: NimbusConf,
                   chainDB: BaseChainDB, protocols: set[ProtocolFlag]) =

  # app wide TxPool singleton
  # TODO: disable some of txPool internal mechanism if
  # the engineSigner is zero.
  nimbus.txPool = TxPoolRef.new(chainDB, conf.engineSigner)

  # metrics logging
  if conf.logMetricsEnabled:
    # https://github.com/nim-lang/Nim/issues/17369
    var logMetrics: proc(udata: pointer) {.gcsafe, raises: [Defect].}
    logMetrics = proc(udata: pointer) =
      {.gcsafe.}:
        let registry = defaultRegistry
      info "metrics", registry
      discard setTimer(Moment.fromNow(conf.logMetricsInterval.seconds), logMetrics)
    discard setTimer(Moment.fromNow(conf.logMetricsInterval.seconds), logMetrics)

  # Provide JWT authentication handler for websockets
  let jwtKey = block:
    # Create or load shared secret
    let rc = nimbus.ctx.rng.jwtSharedSecret(conf)
    if rc.isErr:
      error "Failed create or load shared secret",
        msg = $(rc.unsafeError) # avoid side effects
      quit(QuitFailure)
    rc.value
  let allowedOrigins = conf.getAllowedOrigins()

  # Provide JWT authentication handler for rpcHttpServer
  let httpJwtAuthHook = httpJwtAuth(jwtKey)
  let httpCorsHook = httpCors(allowedOrigins)

  # Creating RPC Server
  if conf.rpcEnabled:
    let enableAuthHook = conf.engineApiEnabled and
                         conf.engineApiPort == conf.rpcPort

    let hooks = if enableAuthHook:
                  @[httpJwtAuthHook, httpCorsHook]
                else:
                  @[httpCorsHook]

    nimbus.rpcServer = newRpcHttpServer(
      [initTAddress(conf.rpcAddress, conf.rpcPort)],
      authHooks = hooks
    )
    setupCommonRpc(nimbus.ethNode, conf, nimbus.rpcServer)

    # Enable RPC APIs based on RPC flags and protocol flags
    let rpcFlags = conf.getRpcFlags()
    if (RpcFlag.Eth in rpcFlags and ProtocolFlag.Eth in protocols) or
       (conf.engineApiPort == conf.rpcPort):
      setupEthRpc(nimbus.ethNode, nimbus.ctx, chainDB, nimbus.txPool, nimbus.rpcServer)
    if RpcFlag.Debug in rpcFlags:
      setupDebugRpc(chainDB, nimbus.rpcServer)

    nimbus.rpcServer.rpc("admin_quit") do() -> string:
      {.gcsafe.}:
        nimbus.state = Stopping
      result = "EXITING"

    nimbus.rpcServer.start()

  # Provide JWT authentication handler for rpcWebsocketServer
  let wsJwtAuthHook = wsJwtAuth(jwtKey)
  let wsCorsHook = wsCors(allowedOrigins)

  # Creating Websocket RPC Server
  if conf.wsEnabled:
    let enableAuthHook = conf.engineApiWsEnabled and
                         conf.engineApiWsPort == conf.wsPort

    let hooks = if enableAuthHook:
                  @[wsJwtAuthHook, wsCorsHook]
                else:
                  @[wsCorsHook]

    # Construct server object
    nimbus.wsRpcServer = newRpcWebSocketServer(
      initTAddress(conf.wsAddress, conf.wsPort),
      authHooks = hooks
    )
    setupCommonRpc(nimbus.ethNode, conf, nimbus.wsRpcServer)

    # Enable Websocket RPC APIs based on RPC flags and protocol flags
    let wsFlags = conf.getWsFlags()
    if (RpcFlag.Eth in wsFlags and ProtocolFlag.Eth in protocols) or
       (conf.engineApiWsPort == conf.wsPort):
      setupEthRpc(nimbus.ethNode, nimbus.ctx, chainDB, nimbus.txPool, nimbus.wsRpcServer)
    if RpcFlag.Debug in wsFlags:
      setupDebugRpc(chainDB, nimbus.wsRpcServer)

    nimbus.wsRpcServer.start()

  if conf.graphqlEnabled:
    nimbus.graphqlServer = setupGraphqlHttpServer(
      conf,
      chainDB,
      nimbus.ethNode,
      nimbus.txPool,
      @[httpCorsHook]
    )
    nimbus.graphqlServer.start()

  if conf.engineSigner != ZERO_ADDRESS:
    let res = nimbus.ctx.am.getAccount(conf.engineSigner)
    if res.isErr:
      error "Failed to get account",
         msg = res.error,
         hint = "--key-store or --import-key"
      quit(QuitFailure)

    let rs = validateSealer(conf, nimbus.ctx, nimbus.chainRef)
    if rs.isErr:
      echo rs.error
      quit(QuitFailure)

    proc signFunc(signer: EthAddress, message: openArray[byte]): Result[RawSignature, cstring] {.gcsafe.} =
      let
        hashData = keccakHash(message)
        acc      = nimbus.ctx.am.getAccount(signer).tryGet()
        rawSign  = sign(acc.privateKey, SkMessage(hashData.data)).toRaw

      ok(rawSign)

    nimbus.chainRef.clique.authorize(conf.engineSigner, signFunc)

  # always create sealing engine instanca but not always run it
  # e.g. engine api need sealing engine without it running
  var initialState = EngineStopped
  if chainDB.headTotalDifficulty() > chainDB.ttd:
     initialState = EnginePostMerge
  nimbus.sealingEngine = SealingEngineRef.new(
    nimbus.chainRef, nimbus.ctx, conf.engineSigner,
    nimbus.txPool, initialState
  )

  # only run sealing engine if there is a signer
  if conf.engineSigner != ZERO_ADDRESS:
    nimbus.sealingEngine.start()

  if conf.engineApiEnabled:
    if conf.engineApiPort != conf.rpcPort:
      nimbus.engineApiServer = newRpcHttpServer(
        [initTAddress(conf.engineApiAddress, conf.engineApiPort)],
        authHooks = @[httpJwtAuthHook, httpCorsHook]
      )
      setupEngineAPI(nimbus.sealingEngine, nimbus.engineApiServer)
      setupEthRpc(nimbus.ethNode, nimbus.ctx, chainDB, nimbus.txPool, nimbus.engineApiServer)
      nimbus.engineApiServer.start()
    else:
      setupEngineAPI(nimbus.sealingEngine, nimbus.rpcServer)

    info "Starting engine API server", port = conf.engineApiPort

  if conf.engineApiWsEnabled:
    if conf.engineApiWsPort != conf.wsPort:
      nimbus.engineApiWsServer = newRpcWebSocketServer(
        initTAddress(conf.engineApiWsAddress, conf.engineApiWsPort),
        authHooks = @[wsJwtAuthHook, wsCorsHook]
      )
      setupEngineAPI(nimbus.sealingEngine, nimbus.engineApiWsServer)
      setupEthRpc(nimbus.ethNode, nimbus.ctx, chainDB, nimbus.txPool, nimbus.engineApiWsServer)
      nimbus.engineApiWsServer.start()
    else:
      setupEngineAPI(nimbus.sealingEngine, nimbus.wsRpcServer)

    info "Starting WebSocket engine API server", port = conf.engineApiWsPort

  # metrics server
  if conf.metricsEnabled:
    info "Starting metrics HTTP server", address = conf.metricsAddress, port = conf.metricsPort
    startMetricsHttpServer($conf.metricsAddress, conf.metricsPort)

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
  let trieDB = trieDB newChainDB(string conf.dataDir)
  var chainDB = newBaseChainDB(trieDB,
    conf.pruneMode == PruneMode.Full,
    conf.networkId,
    conf.networkParams
    )
  chainDB.populateProgress()

  if canonicalHeadHashKey().toOpenArray notin trieDB:
    initializeEmptyDb(chainDB)
    doAssert(canonicalHeadHashKey().toOpenArray in trieDB)

  let protocols = conf.getProtocolFlags()

  case conf.cmd
  of NimbusCmd.`import`:
    importBlocks(conf, chainDB)
  else:
    manageAccounts(nimbus, conf)
    setupP2P(nimbus, conf, chainDB, protocols)
    localServices(nimbus, conf, chainDB, protocols)

    if ProtocolFlag.Eth in protocols and conf.maxPeers > 0:
      case conf.syncMode:
      of SyncMode.Default:
        FastSyncCtx.new(nimbus.ethNode).start
      of SyncMode.Full, SyncMode.Snap:
        discard

    if nimbus.state == Starting:
      # it might have been set to "Stopping" with Ctrl+C
      nimbus.state = Running

proc stop*(nimbus: NimbusNode, conf: NimbusConf) {.async, gcsafe.} =
  trace "Graceful shutdown"
  if conf.rpcEnabled:
    await nimbus.rpcServer.stop()
  # nimbus.engineApiServer can be nil if conf.engineApiPort == conf.rpcPort
  if conf.engineApiEnabled and nimbus.engineApiServer.isNil.not:
    await nimbus.engineApiServer.stop()
  if conf.wsEnabled:
    nimbus.wsRpcServer.stop()
  # nimbus.engineApiWsServer can be nil if conf.engineApiWsPort == conf.wsPort
  if conf.engineApiWsEnabled and nimbus.engineApiWsServer.isNil.not:
    nimbus.engineApiWsServer.stop()
  if conf.graphqlEnabled:
    await nimbus.graphqlServer.stop()
  if conf.engineSigner != ZERO_ADDRESS:
    await nimbus.sealingEngine.stop()

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

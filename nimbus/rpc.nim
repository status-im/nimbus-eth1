# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronicles,
  websock/websock,
  json_rpc/rpcserver,
  graphql/httpserver,
  ./rpc/common,
  ./rpc/debug,
  ./rpc/engine_api,
  ./rpc/p2p,
  ./rpc/jwt_auth,
  ./rpc/cors,
  ./rpc/rpc_server,
  ./rpc/experimental,
  ./nimbus_desc,
  ./graphql/ethapi

export
  common,
  debug,
  engine_api,
  p2p,
  jwt_auth,
  cors,
  rpc_server,
  experimental

{.push gcsafe, raises: [].}

const DefaultChunkSize = 8192

func serverEnabled(conf: NimbusConf): bool =
  conf.httpServerEnabled or
    conf.engineApiServerEnabled

func combinedServer(conf: NimbusConf): bool =
  conf.httpServerEnabled and
    conf.shareServerWithEngineApi

proc installRPC(server: RpcServer,
                nimbus: NimbusNode,
                conf: NimbusConf,
                com: CommonRef,
                flags: set[RpcFlag]) =

  setupCommonRpc(nimbus.ethNode, conf, server)

  if RpcFlag.Eth in flags:
    setupEthRpc(nimbus.ethNode, nimbus.ctx, com, nimbus.txPool, server)

  if RpcFlag.Debug in flags:
    setupDebugRpc(com, nimbus.txPool, server)

  if RpcFlag.Exp in flags:
    setupExpRpc(com, server)

  server.rpc("admin_quit") do() -> string:
    {.gcsafe.}:
      nimbus.state = NimbusState.Stopping
    result = "EXITING"

proc newRpcWebsocketHandler(): RpcWebSocketHandler =
  let rng = HmacDrbgContext.new()
  RpcWebSocketHandler(
    wsserver: WSServer.new(rng = rng),
  )

proc newRpcHttpHandler(): RpcHttpHandler =
  RpcHttpHandler(
    maxChunkSize: DefaultChunkSize,
  )

proc addHandler(handlers: var seq[RpcHandlerProc],
                server: RpcHttpHandler) =

  proc handlerProc(request: HttpRequestRef):
        Future[RpcHandlerResult] {.async: (raises: []).} =
    try:
      let res = await server.serveHTTP(request)
      if res.isNil:
        return RpcHandlerResult(status: RpcHandlerStatus.Skip)
      else:
        return RpcHandlerResult(status: RpcHandlerStatus.Response, response: res)
    except CancelledError:
      return RpcHandlerResult(status: RpcHandlerStatus.Error)

  handlers.add handlerProc

proc addHandler(handlers: var seq[RpcHandlerProc],
                server: RpcWebSocketHandler) =

  proc handlerProc(request: HttpRequestRef):
        Future[RpcHandlerResult] {.async: (raises: []).} =

    if not request.headers.contains("Sec-WebSocket-Version"):
      return RpcHandlerResult(status: RpcHandlerStatus.Skip)

    let stream = websock.AsyncStream(
      reader: request.connection.mainReader,
      writer: request.connection.mainWriter,
    )

    let req = websock.HttpRequest(
      meth: request.meth,
      uri: request.uri,
      version: request.version,
      headers: request.headers,
      stream: stream,
    )

    try:
      await server.serveHTTP(req)
      return RpcHandlerResult(status: RpcHandlerStatus.KeepConnection)
    except CancelledError:
      return RpcHandlerResult(status: RpcHandlerStatus.Error)

  handlers.add handlerProc

proc addHandler(handlers: var seq[RpcHandlerProc],
                server: GraphqlHttpHandlerRef) =

  proc handlerProc(request: HttpRequestRef):
        Future[RpcHandlerResult] {.async: (raises: []).} =
    try:
      let res = await server.serveHTTP(request)
      if res.isNil:
        return RpcHandlerResult(status: RpcHandlerStatus.Skip)
      else:
        return RpcHandlerResult(status: RpcHandlerStatus.Response, response: res)
    except CatchableError:
      return RpcHandlerResult(status: RpcHandlerStatus.Error)

  handlers.add handlerProc

proc addHttpServices(handlers: var seq[RpcHandlerProc],
                     nimbus: NimbusNode, conf: NimbusConf,
                     com: CommonRef, protocols: set[ProtocolFlag]) =

  # The order is important: graphql, ws, rpc
  # graphql depends on /graphl path
  # ws depends on Sec-WebSocket-Version header
  # json-rpc have no reliable identification

  if conf.graphqlEnabled:
    let ctx = setupGraphqlContext(com, nimbus.ethNode, nimbus.txPool)
    let server = GraphqlHttpHandlerRef.new(ctx)
    handlers.addHandler(server)

  if conf.wsEnabled:
    let server = newRpcWebsocketHandler()
    var rpcFlags = conf.getWsFlags()
    if ProtocolFlag.Eth in protocols: rpcFlags.incl RpcFlag.Eth
    installRPC(server, nimbus, conf, com, rpcFlags)
    handlers.addHandler(server)

  if conf.rpcEnabled:
    let server = newRpcHttpHandler()
    var rpcFlags = conf.getRpcFlags()
    if ProtocolFlag.Eth in protocols: rpcFlags.incl RpcFlag.Eth
    installRPC(server, nimbus, conf, com, rpcFlags)
    handlers.addHandler(server)

proc addEngineApiServices(handlers: var seq[RpcHandlerProc],
                          nimbus: NimbusNode, conf: NimbusConf,
                          com: CommonRef) =

  # The order is important: ws, rpc

  if conf.engineApiWsEnabled:
    let server = newRpcWebsocketHandler()
    setupEngineAPI(nimbus.beaconEngine, server)
    installRPC(server, nimbus, conf, com, {RpcFlag.Eth})
    handlers.addHandler(server)

  if conf.engineApiEnabled:
    let server = newRpcHttpHandler()
    setupEngineAPI(nimbus.beaconEngine, server)
    installRPC(server, nimbus, conf, com, {RpcFlag.Eth})
    handlers.addHandler(server)

proc addServices(handlers: var seq[RpcHandlerProc],
                 nimbus: NimbusNode, conf: NimbusConf,
                 com: CommonRef, protocols: set[ProtocolFlag]) =

  # The order is important: graphql, ws, rpc

  if conf.graphqlEnabled:
    let ctx = setupGraphqlContext(com, nimbus.ethNode, nimbus.txPool)
    let server = GraphqlHttpHandlerRef.new(ctx)
    handlers.addHandler(server)

  if conf.wsEnabled or conf.engineApiWsEnabled:
    let server = newRpcWebsocketHandler()
    if conf.engineApiWsEnabled:
      setupEngineAPI(nimbus.beaconEngine, server)
      if not conf.wsEnabled:
        installRPC(server, nimbus, conf, com, {RpcFlag.Eth})

    if conf.wsEnabled:
      var rpcFlags = conf.getWsFlags()
      if ProtocolFlag.Eth in protocols: rpcFlags.incl RpcFlag.Eth
      installRPC(server, nimbus, conf, com, rpcFlags)
    handlers.addHandler(server)

  if conf.rpcEnabled or conf.engineApiEnabled:
    let server = newRpcHttpHandler()
    if conf.engineApiEnabled:
      setupEngineAPI(nimbus.beaconEngine, server)
      if not conf.rpcEnabled:
        installRPC(server, nimbus, conf, com, {RpcFlag.Eth})

    if conf.rpcEnabled:
      var rpcFlags = conf.getRpcFlags()
      if ProtocolFlag.Eth in protocols: rpcFlags.incl RpcFlag.Eth
      installRPC(server, nimbus, conf, com, rpcFlags)
    handlers.addHandler(server)

proc setupRpc*(nimbus: NimbusNode, conf: NimbusConf,
               com: CommonRef, protocols: set[ProtocolFlag]) =
  if not conf.serverEnabled:
    return

  # Provide JWT authentication handler for rpcHttpServer
  let jwtKey = block:
    # Create or load shared secret
    let rc = nimbus.ctx.rng.jwtSharedSecret(conf)
    if rc.isErr:
      fatal "Failed create or load shared secret",
        msg = $(rc.unsafeError) # avoid side effects
      quit(QuitFailure)
    rc.value

  let
    allowedOrigins = conf.getAllowedOrigins()
    jwtAuthHook = httpJwtAuth(jwtKey)
    corsHook = httpCors(allowedOrigins)

  if conf.combinedServer:
    let hooks = @[jwtAuthHook, corsHook]
    var handlers: seq[RpcHandlerProc]
    handlers.addServices(nimbus, conf, com, protocols)
    let address = initTAddress(conf.httpAddress, conf.httpPort)
    let res = newHttpServerWithParams(address, hooks, handlers)
    if res.isErr:
      fatal "Cannot create RPC server", msg=res.error
      quit(QuitFailure)
    nimbus.httpServer = res.get
    nimbus.httpServer.start()
    return

  if conf.httpServerEnabled:
    let hooks = @[corsHook]
    var handlers: seq[RpcHandlerProc]
    handlers.addHttpServices(nimbus, conf, com, protocols)
    let address = initTAddress(conf.httpAddress, conf.httpPort)
    let res = newHttpServerWithParams(address, hooks, handlers)
    if res.isErr:
      fatal "Cannot create RPC server", msg=res.error
      quit(QuitFailure)
    nimbus.httpServer = res.get
    nimbus.httpServer.start()

  if conf.engineApiServerEnabled:
    let hooks = @[jwtAuthHook, corsHook]
    var handlers: seq[RpcHandlerProc]
    handlers.addEngineApiServices(nimbus, conf, com)
    let address = initTAddress(conf.engineApiAddress, conf.engineApiPort)
    let res = newHttpServerWithParams(address, hooks, handlers)
    if res.isErr:
      fatal "Cannot create RPC server", msg=res.error
      quit(QuitFailure)
    nimbus.engineApiServer = res.get
    nimbus.engineApiServer.start()

{.pop.}

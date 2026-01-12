# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  chronicles,
  websock/websock,
  json_rpc/rpcserver,
  ./rpc/[common, cors, debug, engine_api, jwt_auth, rpc_server, server_api],
  ./[conf, nimbus_desc]

export
  common,
  debug,
  engine_api,
  jwt_auth,
  cors,
  rpc_server,
  server_api

const DefaultChunkSize = 1024*1024

func serverEnabled(config: ExecutionClientConf): bool =
  config.httpServerEnabled or
    config.engineApiServerEnabled

func combinedServer(config: ExecutionClientConf): bool =
  config.httpServerEnabled and
    config.shareServerWithEngineApi

func installRPC(server: RpcServer,
                nimbus: NimbusNode,
                config: ExecutionClientConf,
                com: CommonRef,
                serverApi: ServerAPIRef,
                flags: set[RpcFlag]) =

  setupCommonRpc(nimbus.ethNode, config, server)

  if RpcFlag.Eth in flags:
    setupServerAPI(serverApi, server, nimbus.accountsManager)

  if RpcFlag.Admin in flags:
    setupAdminRpc(nimbus, config, server)

  if RpcFlag.Debug in flags:
    setupDebugRpc(com, nimbus.txPool, server)


proc newRpcWebsocketHandler(): RpcWebSocketHandler =
  let rng = HmacDrbgContext.new()
  RpcWebSocketHandler(
    wsserver: WSServer.new(rng = rng),
  )

func newRpcHttpHandler(): RpcHttpHandler =
  RpcHttpHandler(
    maxChunkSize: DefaultChunkSize,
  )

func addHandler(handlers: var seq[RpcHandlerProc],
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

func addHandler(handlers: var seq[RpcHandlerProc],
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

proc addHttpServices(handlers: var seq[RpcHandlerProc],
                     nimbus: NimbusNode, config: ExecutionClientConf,
                     com: CommonRef, serverApi: ServerAPIRef,
                     address: TransportAddress) =

  # The order is important: graphql, ws, rpc
  # graphql depends on /graphl path
  # ws depends on Sec-WebSocket-Version header
  # json-rpc have no reliable identification

  if config.wsEnabled:
    let server = newRpcWebsocketHandler()
    let rpcFlags = config.getWsFlags() + {RpcFlag.Eth}
    installRPC(server, nimbus, config, com, serverApi, rpcFlags)
    handlers.addHandler(server)
    info "JSON-RPC WebSocket API enabled", url = "ws://" & $address

  if config.rpcEnabled:
    let server = newRpcHttpHandler()
    let rpcFlags = config.getRpcFlags() + {RpcFlag.Eth}
    installRPC(server, nimbus, config, com, serverApi, rpcFlags)
    handlers.addHandler(server)
    info "JSON-RPC API enabled", url = "http://" & $address

proc addEngineApiServices(handlers: var seq[RpcHandlerProc],
                          nimbus: NimbusNode, config: ExecutionClientConf,
                          com: CommonRef, serverApi: ServerAPIRef,
                          address: TransportAddress) =

  # The order is important: ws, rpc

  if config.engineApiWsEnabled:
    let server = newRpcWebsocketHandler()
    setupEngineAPI(nimbus.beaconEngine, server)
    installRPC(server, nimbus, config, com, serverApi, {RpcFlag.Eth})
    handlers.addHandler(server)
    info "Engine WebSocket API enabled", url = "ws://" & $address

  if config.engineApiEnabled:
    let server = newRpcHttpHandler()
    setupEngineAPI(nimbus.beaconEngine, server)
    installRPC(server, nimbus, config, com, serverApi, {RpcFlag.Eth})
    handlers.addHandler(server)
    info "Engine API enabled", url = "http://" & $address

proc addServices(handlers: var seq[RpcHandlerProc],
                 nimbus: NimbusNode, config: ExecutionClientConf,
                 com: CommonRef, serverApi: ServerAPIRef,
                 address: TransportAddress) =

  # The order is important: ws, rpc

  if config.wsEnabled or config.engineApiWsEnabled:
    let server = newRpcWebsocketHandler()
    if config.engineApiWsEnabled:
      setupEngineAPI(nimbus.beaconEngine, server)

      if not config.wsEnabled:
        installRPC(server, nimbus, config, com, serverApi, {RpcFlag.Eth})

      info "Engine WebSocket API enabled", url = "ws://" & $address

    if config.wsEnabled:
      let rpcFlags = config.getWsFlags() + {RpcFlag.Eth}
      installRPC(server, nimbus, config, com, serverApi, rpcFlags)
      info "JSON-RPC WebSocket API enabled", url = "ws://" & $address

    handlers.addHandler(server)

  if config.rpcEnabled or config.engineApiEnabled:
    let server = newRpcHttpHandler()
    if config.engineApiEnabled:
      setupEngineAPI(nimbus.beaconEngine, server)
      if not config.rpcEnabled:
        installRPC(server, nimbus, config, com, serverApi, {RpcFlag.Eth})

      info "Engine API enabled", url = "http://" & $address

    if config.rpcEnabled:
      let rpcFlags = config.getRpcFlags() + {RpcFlag.Eth}
      installRPC(server, nimbus, config, com, serverApi, rpcFlags)

      info "JSON-RPC API enabled", url = "http://" & $address

    handlers.addHandler(server)

proc setupRpc*(nimbus: NimbusNode, config: ExecutionClientConf,
               com: CommonRef) =
  if not config.engineApiEnabled:
    warn "Engine API disabled, the node will not respond to consensus client updates (enable with `--engine-api`)"

  if not config.serverEnabled:
    return

  # Provide JWT authentication handler for rpcHttpServer
  let
    jwtKey = nimbus.rng.jwtSharedSecret(config).valueOr:
      fatal "Failed create or load shared secret", error
      quit(QuitFailure)
    allowedOrigins = config.getAllowedOrigins()
    jwtAuthHook = httpJwtAuth(jwtKey)
    corsHook = httpCors(allowedOrigins)
    serverApi = newServerAPI(nimbus.txPool)

  if config.combinedServer:
    let hooks: seq[RpcAuthHook] = @[jwtAuthHook, corsHook]
    var handlers: seq[RpcHandlerProc]
    let address = initTAddress(config.httpAddress, config.httpPort)
    handlers.addServices(nimbus, config, com, serverApi, address)
    let res = newHttpServerWithParams(address, hooks, handlers)
    if res.isErr:
      fatal "Cannot create RPC server", msg=res.error
      quit(QuitFailure)
    nimbus.httpServer = res.get
    nimbus.httpServer.start()
    return

  if config.httpServerEnabled:
    let hooks = @[corsHook]
    var handlers: seq[RpcHandlerProc]
    let address = initTAddress(config.httpAddress, config.httpPort)
    handlers.addHttpServices(nimbus, config, com, serverApi, address)
    let res = newHttpServerWithParams(address, hooks, handlers)
    if res.isErr:
      fatal "Cannot create RPC server", msg=res.error
      quit(QuitFailure)
    nimbus.httpServer = res.get
    nimbus.httpServer.start()

  if config.engineApiServerEnabled:
    let hooks = @[jwtAuthHook, corsHook]
    var handlers: seq[RpcHandlerProc]
    let address = initTAddress(config.engineApiAddress, config.engineApiPort)
    handlers.addEngineApiServices(nimbus, config, com, serverApi, address)
    let res = newHttpServerWithParams(address, hooks, handlers)
    if res.isErr:
      fatal "Cannot create RPC server", msg=res.error
      quit(QuitFailure)
    nimbus.engineApiServer = res.get
    nimbus.engineApiServer.start()

# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when false:
  import
    std/importutils

import
  json_rpc/servers/httpserver as jrpc_server,
  chronos/apps/http/httpserver {.all.}

type
  RpcHttpServerParams = object
    serverFlags: set[HttpServerFlags]
    socketFlags: set[ServerFlags]
    serverUri: Uri
    serverIdent: string
    maxConnections: int
    bufferSize: int
    backlogSize: int
    httpHeadersTimeout: Duration
    maxHeadersSize: int
    maxRequestBodySize: int

  RpcHandlerStatus* {.pure.} = enum
    Skip
    Response
    KeepConnection
    Error

  RpcHandlerResult* = object
    status*: RpcHandlerStatus
    response*: HttpResponseRef

  RpcProcessExitType* {.pure.} = enum
    KeepAlive
    Graceful
    Immediate
    KeepConnection

  RpcAuthHook* = HttpAuthHook

  RpcHandlerProc* = proc(request: HttpRequestRef): Future[RpcHandlerResult]
                      {.async: (raises: []).}

  NimbusHttpServer* = object of RootObj
    server: HttpServerRef
    authHooks: seq[RpcAuthHook]
    handlers: seq[RpcHandlerProc]

  NimbusHttpServerRef* = ref NimbusHttpServer

{.push gcsafe, raises: [].}

func defaultRpcHttpServerParams(): RpcHttpServerParams =
  RpcHttpServerParams(
    socketFlags: {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
    serverUri: Uri(),
    serverIdent: "",
    maxConnections: -1,
    bufferSize: 4096,
    backlogSize: 100,
    httpHeadersTimeout: 10.seconds,
    maxHeadersSize: 64 * 1024,
    # Needs to accomodate a large block and all its blobs, with json overhead
    maxRequestBodySize: 16 * 1024 * 1024,
  )

proc resolvedAddress(address: string): Result[TransportAddress, string] =
  var tas: seq[TransportAddress]

  try:
    tas = resolveTAddress(address, AddressFamily.IPv4)
    if tas.len == 1:
      return ok(tas[0])
    if tas.len > 1:
      return err("Too much address for HTTP server: " & $tas.len)
  except CatchableError:
    # It might be an IPv6
    discard

  try:
    tas = resolveTAddress(address, AddressFamily.IPv6)
    if tas.len == 1:
      return ok(tas[0])
    if tas.len > 1:
      return err("Too much address for HTTP server: " & $tas.len)
    if tas.len == 0:
      return err("No address found for HTTP server")
  except CatchableError:
    return err("Failed to decode HTTP server address")

proc createServer(address: TransportAddress,
                  params: RpcHttpServerParams): HttpResult[HttpServerRef] =

  proc processCallback(req: RequestFence):
          Future[HttpResponseRef] {.
            async: (raises: [CancelledError]).} =
    # This is a dummy callback because we are going to
    # create our own callback
    return nil

  HttpServerRef.new(
    address,
    processCallback,
    params.serverFlags,
    params.socketFlags,
    params.serverUri,
    params.serverIdent,
    params.maxConnections,
    params.bufferSize,
    params.backlogSize,
    params.httpHeadersTimeout,
    params.maxHeadersSize,
    params.maxRequestBodySize)

proc createServer(address: string,
                  params: RpcHttpServerParams): HttpResult[HttpServerRef] =
  ## Create new server and assign it to ``address``.
  let serverAddress = resolvedAddress(address).valueOr:
    return err(error)
  createServer(serverAddress, params)

proc newHttpServerWithParams*(address: TransportAddress or string,
                              authHooks: sink seq[RpcAuthHook] = @[],
                              handlers: sink seq[RpcHandlerProc]):
                                HttpResult[NimbusHttpServerRef] =
  ## Create new server and assign it to ``address``.
  let params = defaultRpcHttpServerParams()
  let inner = createServer(address, params)
  if inner.isErr:
    return err(inner.error)

  let server = NimbusHttpServerRef(
    server: inner.get,
    authHooks: system.move(authHooks),
    handlers: system.move(handlers),
  )

  return ok(server)

proc invokeProcessCallback(nserver: NimbusHttpServerRef,
                           req: RequestFence): Future[RpcHandlerResult] {.
     async: (raises: []).} =
  when false:
    let server = nserver.server
    privateAccess(type server)
    if len(server.middlewares) > 0:
      server.middlewares[0](req)
    else:
      server.processCallback(req)

  if req.isErr:
    return RpcHandlerResult(
      status: RpcHandlerStatus.Response,
      response: defaultResponse(),
    )

  let request = req.get()
  # If hook result is not nil,
  # it means we should return immediately
  try:
    for hook in nserver.authHooks:
      let res = await hook(request)
      if not res.isNil:
        return RpcHandlerResult(
          status: RpcHandlerStatus.Response,
          response: res,
        )
  except CatchableError as exc:
    return RpcHandlerResult(
      status: RpcHandlerStatus.Response,
      response: defaultResponse(exc),
    )

  # If handler result.status != Skip,
  # return immediately
  for handler in nserver.handlers:
    let res = await handler(request)
    if res.status != RpcHandlerStatus.Skip:
      return res

  # not handled
  return RpcHandlerResult(
    status: RpcHandlerStatus.Response,
    response: defaultResponse(),
  )

proc processRequest(nserver: NimbusHttpServerRef,
                    connection: HttpConnectionRef,
                    connId: string): Future[RpcProcessExitType] {.
     async: (raises: []).} =
  let server = nserver.server
  let requestFence = await getRequestFence(server, connection)
  if requestFence.isErr():
    case requestFence.error.kind
    of HttpServerError.InterruptError:
      # Cancelled, exiting
      return RpcProcessExitType.Immediate
    of HttpServerError.DisconnectError:
      # Remote peer disconnected
      if HttpServerFlags.NotifyDisconnect notin server.flags:
        return RpcProcessExitType.Immediate
    else:
      # Request is incorrect or unsupported, sending notification
      discard

  try:
    let response =
      try:
        await invokeProcessCallback(nserver, requestFence)
      except CancelledError:
        # Cancelled, exiting
        return RpcProcessExitType.Immediate

    case response.status
    of RpcHandlerStatus.Skip: discard
    of RpcHandlerStatus.Response:
      let res = await connection.sendDefaultResponse(requestFence, response.response)
      return RpcProcessExitType(res.ord)
    of RpcHandlerStatus.KeepConnection:
      return RpcProcessExitType.KeepConnection
    of RpcHandlerStatus.Error:
      return RpcProcessExitType.Immediate
  finally:
    if requestFence.isOk():
      let request = requestFence.get()
      if result == RpcProcessExitType.KeepConnection:
        request.response = Opt.none(HttpResponseRef)
      await request.closeWait()

proc processLoop(nserver: NimbusHttpServerRef, holder: HttpConnectionHolderRef) {.async: (raises: []).} =
  let
    server = holder.server
    transp = holder.transp
    connectionId = holder.connectionId
    connection =
      block:
        let res = await getConnectionFence(server, transp)
        if res.isErr():
          if res.error.kind != HttpServerError.InterruptError:
            discard await noCancel(
              invokeProcessCallback(nserver, RequestFence.err(res.error)))
          server.connections.del(connectionId)
          return
        res.get()

  holder.connection = connection

  var runLoop = RpcProcessExitType.KeepAlive
  while runLoop == RpcProcessExitType.KeepAlive:
    runLoop = await nserver.processRequest(connection, connectionId)

  case runLoop
  of RpcProcessExitType.KeepAlive:
    await connection.closeWait()
  of RpcProcessExitType.Immediate:
    await connection.closeWait()
  of RpcProcessExitType.Graceful:
    await connection.gracefulCloseWait()
  of RpcProcessExitType.KeepConnection:
    discard
  server.connections.del(connectionId)

proc acceptClientLoop(nserver: NimbusHttpServerRef) {.async: (raises: []).} =
  let server = nserver.server
  var runLoop = true
  while runLoop:
    try:
      let transp = await server.instance.accept()
      let resId = transp.getId()
      if resId.isErr():
        # We are unable to identify remote peer, it means that remote peer
        # disconnected before identification.
        await transp.closeWait()
        runLoop = false
      else:
        let connId = resId.get()
        let holder = HttpConnectionHolderRef.new(server, transp, resId.get())
        server.connections[connId] = holder
        holder.future = processLoop(nserver, holder)
    except TransportTooManyError, TransportAbortedError:
      # Non-critical error
      discard
    except CancelledError, TransportOsError, CatchableError:
      # Critical, cancellation or unexpected error
      runLoop = false

proc start*(server: NimbusHttpServerRef) =
  if server.server.state == ServerStopped:
    server.server.acceptLoop = acceptClientLoop(server)

proc stop*(server: NimbusHttpServerRef) {.async: (raises: []).} =
  await server.server.stop()

proc closeWait*(server: NimbusHttpServerRef) {.async: (raises: []).} =
  await server.server.closeWait()

func localAddress*(server: NimbusHttpServerRef): TransportAddress =
  server.server.instance.localAddress()

proc addServer*(server: RpcHttpServer,
                address: TransportAddress,
                params: RpcHttpServerParams): Result[void, string] =
  try:
    server.addHttpServer(
      address,
      params.socketFlags,
      params.serverUri,
      params.serverIdent,
      params.maxConnections,
      params.bufferSize,
      params.backlogSize,
      params.httpHeadersTimeout,
      params.maxHeadersSize,
      params.maxRequestBodySize)
    return ok()
  except CatchableError as exc:
    return err(exc.msg)

proc addServer*(server: RpcHttpServer,
                address: string,
                params: RpcHttpServerParams): Result[void, string] =
  let serverAddress = resolvedAddress(address).valueOr:
    return err(error)

  server.addServer(serverAddress, params)

proc newRpcHttpServerWithParams*(address: TransportAddress,
            authHooks: seq[HttpAuthHook] = @[]): Result[RpcHttpServer, string] =
  ## Create new server and assign it to addresses ``addresses``.
  let server = RpcHttpServer.new(authHooks)
  let params = defaultRpcHttpServerParams()
  server.addServer(address, params).isOkOr:
    return err(error)
  ok(server)

proc newRpcHttpServerWithParams*(address: string,
            authHooks: seq[HttpAuthHook] = @[]): Result[RpcHttpServer, string] =
  let server = RpcHttpServer.new(authHooks)
  let params = defaultRpcHttpServerParams()
  server.addServer(address, params).isOkOr:
    return err(error)
  ok(server)

{.pop.}

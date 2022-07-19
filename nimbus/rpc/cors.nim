# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[uri],
  chronos,
  chronos/apps/http/[httptable, httpserver],
  json_rpc/rpcserver,
  httputils,
  websock/websock as ws,
  ../config

proc sameOrigin(a, b: Uri): bool =
  a.hostname == b.hostname and
    a.scheme == b.scheme and
    a.port == b.port

proc containsOrigin(list: seq[Uri], origin: Uri): bool =
  for x in list:
    if x.sameOrigin(origin): return true

const
  HookOK = HttpResponseRef(nil)

proc httpCors*(allowedOrigins: seq[Uri]): HttpAuthHook =
  proc handler(req: HttpRequestRef): Future[HttpResponseRef] {.async.} =
    let origins = req.headers.getList("Origin")
    let everyOriginAllowed = allowedOrigins.len == 0

    if origins.len > 1:
      return await req.respond(Http400,
        "Only a single Origin header must be specified")

    if origins.len == 0:
      # maybe not a CORS request
      return HookOK

    # this section shared by all http method
    let origin = parseUri(origins[0])
    let resp = req.getResponse()
    if not allowedOrigins.containsOrigin(origin):
      return await req.respond(Http403, "Origin not allowed")

    if everyOriginAllowed:
      resp.addHeader("Access-Control-Allow-Origin", "*")
    else:
      # The Vary: Origin header to must be set to prevent
      # potential cache poisoning attacks:
      # https://textslashplain.com/2018/08/02/cors-and-vary/
      resp.addHeader("Vary", "Origin")
      resp.addHeader("Access-Control-Allow-Origin", origins[0])

    if req.meth == MethodOptions:
      # Preflight request
      let meth = resp.getHeader("Access-Control-Request-Method", "?")
      if meth != "?":
        # TODO: get actual methods supported by respective server
        # e.g. JSON-RPC, GRAPHQL, ENGINE-API
        resp.addHeader("Access-Control-Allow-Methods", "GET, POST")
        resp.addHeader("Vary", "Access-Control-Request-Method")

      let heads = resp.getHeader("Access-Control-Request-Headers", "?")
      if heads != "?":
        # TODO: get actual headers supported by each server?
        resp.addHeader("Access-Control-Allow-Headers", heads)
        resp.addHeader("Vary", "Access-Control-Request-Headers")
      return await req.respond(Http400)

    # other method such as POST or GET will fill
    # the rest of response in server
    return HookOK

  result = HttpAuthHook(handler)

proc wsCors*(allowedOrigins: seq[Uri]): WsAuthHook =
  proc handler(req: ws.HttpRequest): Future[bool] {.async.} =
    # TODO: implement websock equivalent of
    # request.getResponse
    return true

  result = WsAuthHook(handler)

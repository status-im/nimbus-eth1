# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
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
  chronos/apps/http/httptable,
  chronos/apps/http/httpserver,
  httputils,
  ./rpc_server

{.push gcsafe, raises: [].}

proc sameOrigin(a, b: Uri): bool =
  a.hostname == b.hostname and a.scheme == b.scheme and a.port == b.port

proc containsOrigin(list: seq[Uri], origin: Uri): bool =
  for x in list:
    if x.sameOrigin(origin):
      return true

const HookOK = HttpResponseRef(nil)

proc httpCors*(allowedOrigins: seq[Uri]): RpcAuthHook =
  proc handler(
      req: HttpRequestRef
  ): Future[HttpResponseRef] {.gcsafe, async: (raises: [CatchableError]).} =
    let origins = req.headers.getList("Origin")
    let everyOriginAllowed = allowedOrigins.len == 0

    if origins.len > 1:
      return await req.respond(Http400, "Only a single Origin header must be specified")

    if origins.len == 0:
      # maybe not a CORS request
      return HookOK

    # this section shared by all http method
    let origin = parseUri(origins[0])
    let resp = req.getResponse()

    if not everyOriginAllowed and not allowedOrigins.containsOrigin(origin):
      return await req.respond(Http403, "Origin not allowed")

    if everyOriginAllowed:
      resp.addHeader("Access-Control-Allow-Origin", "*")
    else:
      # The Vary: Origin header to must be set to prevent
      # potential cache poisoning attacks:
      # https://textslashplain.com/2018/08/02/cors-and-vary/
      resp.addHeader("Vary", "Origin")
      resp.addHeader("Access-Control-Allow-Origin", origins[0])

    let methods = req.headers.getList("Access-Control-Request-Method")

    # Check it this is preflight request
    # There are three conditions to identify proper preflight request:
    # - Origin header is present (we checked this earlier)
    # - It uses OPTIONS method
    # - It has Access-Control-Request-Method header
    if req.meth == MethodOptions and len(methods) > 0:
      # TODO: get actual methods supported by respective server
      # e.g. JSON-RPC, GRAPHQL, ENGINE-API
      resp.addHeader("Access-Control-Allow-Methods", "GET, POST")
      resp.addHeader("Vary", "Access-Control-Request-Method")

      # check headers
      let headers = req.headers.getString("Access-Control-Request-Headers", "?")

      if headers != "?":
        # TODO: get actual headers supported by each server?
        resp.addHeader("Access-Control-Allow-Headers", headers)
        resp.addHeader("Vary", "Access-Control-Request-Headers")

      # Response to preflight request should be in 200 range.
      return await req.respond(Http204)

    # other method such as POST or GET will fill
    # the rest of response in server
    return HookOK

  result = handler

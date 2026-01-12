# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.
#
# Ackn:
#   go-ethereum/node/jwt_handler.go

{.push gcsafe, raises: [].}

import
  std/[options, strutils, times],
  stew/base64,
  bearssl/rand,
  chronicles,
  chronos,
  chronos/apps/http/httptable,
  chronos/apps/http/httpserver,
  httputils,
  nimcrypto/[hmac, sha2],
  results,
  ../conf,
  ./jwt_auth_helper,
  ./rpc_server,
  beacon_chain/spec/engine_authentication

export engine_authentication

logScope:
  topics = "Jwt/HS256 auth"

type
  JwtGenSecret* = ##\
    ## Random generator function producing a shared key. Typically, this\
    ## will be a wrapper around a random generator type, such as\
    ## `HmacDrbgContext`.
    proc(): JwtSharedKey {.gcsafe, raises: [CatchableError].}

  JwtExcept* = object of CatchableError ## Catch and relay exception error

  JwtError* = enum
    jwtTokenInvNumSegments = "token contains an invalid number of segments"
    jwtProtHeaderInvBase64 = "token protected header invalid base64 encoding"
    jwtProtHeaderInvJson = "token protected header invalid JSON data"
    jwtIatPayloadInvBase64 = "iat payload time invalid base64 encoding"
    jwtIatPayloadInvJson = "iat payload time invalid JSON data"
    jwtMethodUnsupported = "token protected header provides unsupported method"
    jwtTimeValidationError = "token time validation failed"
    jwtTokenValidationError = "token signature validation failed"
    jwtCreationError = "Cannot create jwt secret"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc verifyTokenHS256(token: string, key: JwtSharedKey): Result[void, JwtError] =
  let p = token.split('.')
  if p.len != 3:
    return err(jwtTokenInvNumSegments)

  var
    time: int64
    error: JwtError
  try:
    # Parse/verify protected header, try first the most common encoding
    # of """{"typ":"JWT","alg":"HS256"}"""
    if p[0] != "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9":
      error = jwtProtHeaderInvBase64
      let jsonHeader = Base64Url.decode(p[0])

      error = jwtProtHeaderInvJson
      let jwtHeader = jsonHeader.decodeJwtHeader()

      # The following JSON decoded object is required
      if jwtHeader.typ != "JWT" and jwtHeader.alg != "HS256":
        return err(jwtMethodUnsupported)

    # Get the time payload
    error = jwtIatPayloadInvBase64
    let jsonPayload = Base64Url.decode(p[1])

    error = jwtIatPayloadInvJson
    let jwtPayload = jsonPayload.decodeJwtIatPayload()
    time = jwtPayload.iat.int64
  except CatchableError as e:
    discard e
    debug "JWT token decoding error",
      protectedHeader = p[0], payload = p[1], msg = e.msg, error
    return err(error)

  # github.com/ethereum/
  #  /execution-apis/blob/v1.0.0-beta.3/src/engine/authentication.md#jwt-claims
  #
  # "Required: iat (issued-at) claim. The EL SHOULD only accept iat timestamps
  #  which are within +-60 seconds from the current time."
  #
  # https://datatracker.ietf.org/doc/html/rfc7519#section-4.1.6 describes iat
  # claims.
  let delta = getTime().toUnix - time
  if delta < -60 or 60 < delta:
    debug "Iat timestamp problem, accepted |delta| <= 5", delta
    return err(jwtTimeValidationError)

  let
    keyArray = distinctBase(key)
    b64sig = Base64Url.encode(sha256.hmac(keyArray, p[0] & "." & p[1]).data)
  if b64sig != p[2]:
    return err(jwtTokenValidationError)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc jwtSharedSecret*(
    rng: Rng, config: ExecutionClientConf
): Result[JwtSharedKey, cstring] =
  ## Return a key for jwt authentication preferable from the argument file
  ## `config.jwtSecret` (which contains at least 32 bytes hex encoded random
  ## data.) Otherwise it creates a key and stores it in the `config.dataDir`.
  ##
  ## The resulting `JwtSharedKey` is supposed to be usewd as argument for
  ## the function `jwtHandlerHS256()`, below.
  ##
  ## Note that this function variant is mainly used for debugging and testing.
  ## For a more common interface prototype with explicit random generator
  ## object see the variant below this one.
  #
  # If such a parameter is given, but the file cannot be read, or does not
  # contain a hex-encoded key of at least 256 bits (aka ``jwtMinSecretLen`
  # bytes.), the client should treat this as an error: either abort the
  # startup, or show error and continue without exposing the authenticated
  # port.
  #
  if config.jwtSecretValue.isSome():
    return parseJwtSharedKey(config.jwtSecretValue.get())

  rng.checkJwtSecret(config.dataDir, config.jwtSecretOpt)

proc jwtSharedSecret*(
    rng: ref rand.HmacDrbgContext, config: ExecutionClientConf
): Result[JwtSharedKey, cstring] =
  ## Variant of `jwtSharedSecret()` with explicit random generator argument.
  jwtSharedSecret(
    proc(v: var openArray[byte]) =
      rng[].generate(v),
    config,
  )

proc httpJwtAuth*(key: JwtSharedKey): RpcAuthHook =
  proc handler(
      req: HttpRequestRef
  ): Future[HttpResponseRef] {.async: (raises: [CatchableError]).} =
    let auth = req.headers.getString("Authorization", "?")
    if auth.len < 9 or auth[0 .. 6].cmpIgnoreCase("Bearer ") != 0:
      return await req.respond(Http403, "Missing authorization token")

    let rc = auth[7 ..^ 1].strip.verifyTokenHS256(key)
    if rc.isOk:
      return HttpResponseRef(nil)

    debug "Could not authenticate", error = rc.error

    case rc.error
    of jwtTokenValidationError, jwtMethodUnsupported:
      return await req.respond(Http401, "Unauthorized access")
    else:
      return await req.respond(Http403, "Malformed token")

  result = handler

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

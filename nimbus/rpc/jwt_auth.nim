# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.
#
# Ackn:
#   nimbus-eth2/beacon_chain/spec/engine_authentication.nim
#   go-ethereum/node/jwt_handler.go

import
  std/[base64, json, options, os, strutils, times],
  bearssl,
  chronicles,
  chronos,
  chronos/apps/http/httptable,
  httputils,
  websock/types as ws,
  nimcrypto/[hmac, utils],
  stew/[byteutils, objects, results],
  ../config

{.push raises: [Defect].}

logScope:
  topics = "Jwt/HS256 auth"

const
  jwtSecretFile* = ##\
    ## A copy on the secret key in the `dataDir` directory
    "jwt.hex"

  jwtMinSecretLen* = ##\
    ## Number of bytes needed with the shared key
    32

type
  # -- currently unused --
  #
  #JwtAuthHandler* = ##\
  #  ## JSW authenticator prototype
  #  proc(req: HttpTable): Result[void,(HttpCode,string)]
  #    {.gcsafe, raises: [Defect].}
  #

  JwtAuthAsyHandler* = ##\
    ## Asynchroneous JSW authenticator prototype. This is the definition
    ## appicable for the `verify` entry of a `ws.Hook`.
    proc(req: HttpTable): Future[Result[void,string]]
      {.closure, gcsafe, raises: [Defect].}

  JwtSharedKey* = ##\
    ## Convenience type, needed quite often
    distinct array[jwtMinSecretLen,byte]

  JwtSharedKeyRaw =
    array[jwtMinSecretLen,byte]

  JwtGenSecret* = ##\
    ## Random generator function producing a shared key. Typically, this\
    ## will be a wrapper around a random generator type, such as\
    ## `BrHmacDrbgContext`.
    proc(): JwtSharedKey {.gcsafe.}

  JwtExcept* = object of CatchableError
    ## Catch and relay exception error

  JwtError* = enum
    jwtKeyTooSmall = "JWT secret not at least 256 bits"
    jwtKeyEmptyFile = "no 0x-prefixed hex string found"
    jwtKeyFileCannotOpen = "couldn't open specified JWT secret file"
    jwtKeyInvalidHexString = "invalid JWT hex string"

    jwtTokenInvNumSegments = "token contains an invalid number of segments"
    jwtProtHeaderInvBase64 = "token protected header invalid base64 encoding"
    jwtProtHeaderInvJson = "token protected header invalid JSON data"
    jwtIatPayloadInvBase64 = "iat payload time invalid base64 encoding"
    jwtIatPayloadInvJson = "iat payload time invalid JSON data"
    jwtMethodUnsupported = "token protected header provides unsupported method"
    jwtTimeValidationError = "token time validation failed"
    jwtTokenValidationError = "token signature validation failed"

  JwtHeader = object ##\
    ## Template used for JSON unmarshalling
    typ, alg: string

  JwtIatPayload = object ##\
    ## Template used for JSON unmarshalling
    iat: uint64

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template safeExecutor(info: string; code: untyped) =
  try:
    code
  except Exception as e:
    raise newException(JwtExcept, info & "(): " & $e.name & " -- " & e.msg)

proc base64urlEncode(x: auto): string =
  # The only strings this gets are internally generated, and don't have
  # encoding quirks.
  base64.encode(x, safe = true).replace("=", "")

proc base64urlDecode(data: string): string
    {.gcsafe, raises: [Defect, CatchableError].} =
  ## Decodes a JWT specific base64url, optionally encoding with stripped
  ## padding.
  let l = data.len mod 4
  if 0 < l:
    return base64.decode(data & "=".repeat(4-l))
  base64.decode(data)

proc verifyTokenHS256(token: string; key: JwtSharedKey): Result[void,JwtError] =
  let p = token.split('.')
  if p.len != 3:
    return err(jwtTokenInvNumSegments)

  var
    time: int64
    error: JwtError
  try:
    # Parse/verify protected header, try first the most common encoding
    # of """{"typ": "JWT", "alg": "HS256"}"""
    if p[0] != "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9":
      error = jwtProtHeaderInvBase64
      let jsonHeader = p[0].base64urlDecode

      error = jwtProtHeaderInvJson
      let jwtHeader = jsonHeader.parseJson.to(JwtHeader)

      # The following JSON decoded object is required
      if jwtHeader.typ != "JWT" and jwtHeader.alg != "HS256":
        return err(jwtMethodUnsupported)

    # Get the time payload
    error = jwtIatPayloadInvBase64
    let jsonPayload = p[1].base64urlDecode

    error = jwtIatPayloadInvJson
    let jwtPayload = jsonPayload.parseJson.to(JwtIatPayload)
    time = jwtPayload.iat.int64
  except:
    debug "JWT token decoding error",
      protectedHeader = p[0],
      payload = p[1],
      error
    return err(error)

  # github.com/ethereum/
  #  /execution-apis/blob/v1.0.0-alpha.8/src/engine/authentication.md#jwt-claims
  #
  # "Required: iat (issued-at) claim. The EL SHOULD only accept iat timestamps
  #  which are within +-5 seconds from the current time."
  #
  # https://datatracker.ietf.org/doc/html/rfc7519#section-4.1.6 describes iat
  # claims.
  let delta = getTime().toUnix - time
  if delta < -5 or 5 < delta:
    debug "Iat timestamp problem, accepted |delta| <= 5",
      delta
    return err(jwtTimeValidationError)

  let
    keyArray = cast[array[jwtMinSecretLen,byte]](key)
    b64sig = base64urlEncode(sha256.hmac(keyArray, p[0] & "." & p[1]).data)
  if b64sig != p[2]:
    return err(jwtTokenValidationError)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fromHex*(key: var JwtSharedkey, src: string): Result[void,JwtError] =
  ## Parse argument `src` from hex-string and fill it into the argument `key`.
  ## This function is supposed to read and convert data in constant-time
  ## fashion, guarding against side channel attacks.
  # utils.fromHex() does the constant-time job
  let secret = utils.fromHex(src)
  if secret.len < jwtMinSecretLen:
    return err(jwtKeyTooSmall)
  key = toArray(JwtSharedKeyRaw.len, secret).JwtSharedKey
  ok()

proc jwtGenSecret*(rng: ref BrHmacDrbgContext): JwtGenSecret =
  ## Standard shared key random generator. If a fixed key is needed, a
  ## function like
  ## ::
  ##   proc preCompiledGenSecret(key: JwtSharedKey): JwtGenSecret =
  ##     result = proc: JwtSharedKey =
  ##       key
  ##
  ## might do. Not that in most cases, this function is internally used,
  ## only.
  result = proc: JwtSharedKey =
    var data: array[jwtMinSecretLen,byte]
    rng[].brHmacDrbgGenerate(data)
    data.JwtSharedKey

proc jwtSharedSecret*(rndSecret: JwtGenSecret; config: NimbusConf):
                    Result[JwtSharedKey, JwtError] =
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
  ##
  ## Ackn nimbus-eth2:
  ##   beacon_chain/spec/engine_authentication.nim.`checkJwtSecret()`
  #
  # If such a parameter is given, but the file cannot be read, or does not
  # contain a hex-encoded key of at least 256 bits (aka ``jwtMinSecretLen`
  # bytes.), the client should treat this as an error: either abort the
  # startup, or show error and continue without exposing the authenticated
  # port.
  #
  if config.jwtSecret.isNone:
    # If such a parameter is not given, the client SHOULD generate such a
    # token, valid for the duration of the execution, and store it the
    # hex-encoded secret as a jwt.hex file on the filesystem. This file can
    # then be used to provision the counterpart client.
    #
    # github.com/ethereum/
    #   /execution-apis/blob/v1.0.0-alpha.8/src/engine/
    #   /authentication.md#key-distribution
    let
      jwtSecretPath = config.dataDir.string / jwtSecretFile
      newSecret = rndSecret()
    try:
      jwtSecretPath.writeFile(newSecret.JwtSharedKeyRaw.to0xHex)
    except IOError as e:
      # Allow continuing to run, though this is effectively fatal for a merge
      # client using authentication. This keeps it lower-risk initially.
      warn "Could not write JWT secret to data directory",
        jwtSecretPath
    return ok(newSecret)

  try:
    let lines = config.jwtSecret.get.string.readLines(1)
    if lines.len == 0:
      return err(jwtKeyEmptyFile)
    var key: JwtSharedkey
    let rc = key.fromHex(lines[0])
    if rc.isErr:
      return err(rc.error)
    return ok(key.JwtSharedKey)
  except IOError:
    return err(jwtKeyFileCannotOpen)
  except ValueError:
    return err(jwtKeyInvalidHexString)

proc jwtSharedSecret*(rng: ref BrHmacDrbgContext; config: NimbusConf):
                    Result[JwtSharedKey, JwtError]
    {.gcsafe, raises: [Defect,JwtExcept].} =
  ## Variant of `jwtSharedSecret()` with explicit random generator argument.
  safeExecutor("jwtSharedSecret"):
    result = rng.jwtGenSecret.jwtSharedSecret(config)


# -- currently unused --
#
#proc jwtAuthHandler*(key: JwtSharedKey): JwtAuthHandler =
#  ## Returns a JWT authentication handler that can be used with an HTTP header
#  ## based call back system.
#  ##
#  ## The argument `key` is captured by the session handler for JWT
#  ## authentication. The function `jwtSharedSecret()` provides such a key.
#  result = proc(req: HttpTable): Result[void,(HttpCode,string)] =
#              let auth = req.getString("Authorization","?")
#              if auth.len < 9 or auth[0..6].cmpIgnoreCase("Bearer ") != 0:
#                return err((Http403, "Missing Token"))
#
#              let rc = auth[7..^1].strip.verifyTokenHS256(key)
#              if rc.isOk:
#                return ok()
#
#              debug "Could not authenticate",
#                error = rc.error
#
#              case rc.error:
#              of jwtTokenValidationError, jwtMethodUnsupported:
#                return err((Http401, "Unauthorized"))
#              else:
#                return err((Http403, "Malformed Token"))
#

proc jwtAuthAsyHandler*(key: JwtSharedKey): JwtAuthAsyHandler =
  ## Returns an asynchroneous JWT authentication handler that can be used with
  ## an HTTP header based call back system.
  ##
  ## The argument `key` is captured by the session handler for JWT
  ## authentication. The function `jwtSharedSecret()` provides such a key.
  result = proc(req: HttpTable): Future[Result[void,string]] {.async.} =
              let auth = req.getString("Authorization","?")
              if auth.len < 9 or auth[0..6].cmpIgnoreCase("Bearer ") != 0:
                return err("Missing Token")

              let rc = auth[7..^1].strip.verifyTokenHS256(key)
              if rc.isOk:
                return ok()

              debug "Could not authenticate",
                error = rc.error

              case rc.error:
              of jwtTokenValidationError, jwtMethodUnsupported:
                return err("Unauthorized")
              else:
                return err("Malformed Token")

proc jwtAuthAsyHook*(key: JwtSharedKey): ws.Hook =
  ## Variant of `jwtAuthHandler()` (e.g. directly suitable for Json WebSockets.)
  ##
  ## Note that currently there is no meaningful way to send a http 401/403 in
  ## case of an authentication problem.
  let handler = key.jwtAuthAsyHandler
  ws.Hook(
    append: proc(ctx: ws.Hook, req: var HttpTable): Result[void,string] =
                ok(),
    verify: proc(ctx: ws.Hook, req: HttpTable): Future[Result[void,string]] =
                req.handler)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
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

{.push gcsafe, raises: [].}

import
  std/[base64, options, strutils, times],
  bearssl/rand,
  chronicles,
  chronos,
  chronos/apps/http/httptable,
  chronos/apps/http/httpserver,
  httputils,
  nimcrypto/[hmac, sha2, utils],
  stew/[byteutils, objects],
  results,
  ../config,
  ./jwt_auth_helper,
  ./rpc_server

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
  JwtSharedKey* = ##\
    ## Convenience type, needed quite often
    distinct array[jwtMinSecretLen,byte]

  JwtSharedKeyRaw =
    array[jwtMinSecretLen,byte]

  JwtGenSecret* = ##\
    ## Random generator function producing a shared key. Typically, this\
    ## will be a wrapper around a random generator type, such as\
    ## `HmacDrbgContext`.
    proc(): JwtSharedKey {.gcsafe, raises: [CatchableError].}

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
    jwtCreationError = "Cannot create jwt secret"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc base64urlEncode(x: auto): string =
  # The only strings this gets are internally generated, and don't have
  # encoding quirks.
  base64.encode(x, safe = true).replace("=", "")

proc base64urlDecode(data: string): string
    {.gcsafe, raises: [CatchableError].} =
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
      let jwtHeader = jsonHeader.decodeJwtHeader()

      # The following JSON decoded object is required
      if jwtHeader.typ != "JWT" and jwtHeader.alg != "HS256":
        return err(jwtMethodUnsupported)

    # Get the time payload
    error = jwtIatPayloadInvBase64
    let jsonPayload = p[1].base64urlDecode

    error = jwtIatPayloadInvJson
    let jwtPayload = jsonPayload.decodeJwtIatPayload()
    time = jwtPayload.iat.int64
  except CatchableError as e:
    discard e
    debug "JWT token decoding error",
      protectedHeader = p[0],
      payload = p[1],
      msg = e.msg,
      error
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

proc fromHex*(key: var JwtSharedKey, src: string): Result[void,JwtError] =
  ## Parse argument `src` from hex-string and fill it into the argument `key`.
  ## This function is supposed to read and convert data in constant-time
  ## fashion, guarding against side channel attacks.
  # utils.fromHex() does the constant-time job
  try:
    let secret = utils.fromHex(src)
    if secret.len < jwtMinSecretLen:
      return err(jwtKeyTooSmall)
    key = toArray(JwtSharedKeyRaw.len, secret).JwtSharedKey
    ok()
  except ValueError:
    err(jwtKeyInvalidHexString)

proc jwtGenSecret*(rng: ref rand.HmacDrbgContext): JwtGenSecret =
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
    rng[].generate(data)
    data.JwtSharedKey

proc jwtSharedSecret*(
    rndSecret: JwtGenSecret;
    config: NimbusConf;
      ): Result[JwtSharedKey, JwtError] =
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
    let jwtSecretPath = config.dataDir.string & "/" & jwtSecretFile
    try:
      let newSecret = rndSecret()
      jwtSecretPath.writeFile(newSecret.JwtSharedKeyRaw.to0xHex)
      notice "JWT secret generated", jwtSecretPath
      return ok(newSecret)
    except IOError as e:
      # Allow continuing to run, though this is effectively fatal for a merge
      # client using authentication. This keeps it lower-risk initially.
      warn "Could not write JWT secret to data directory",
        jwtSecretPath
      discard e
    except CatchableError:
      return err(jwtCreationError)

  try:
    let lines = config.jwtSecret.get.string.readLines(1)
    if lines.len == 0:
      return err(jwtKeyEmptyFile)
    var key: JwtSharedKey
    let rc = key.fromHex(lines[0])
    if rc.isErr:
      return err(rc.error)
    info "JWT secret loaded", jwtSecretPath = config.jwtSecret.get.string
    return ok(key)
  except IOError:
    return err(jwtKeyFileCannotOpen)
  except ValueError:
    return err(jwtKeyInvalidHexString)

proc jwtSharedSecret*(rng: ref rand.HmacDrbgContext; config: NimbusConf):
                    Result[JwtSharedKey, JwtError] =
  ## Variant of `jwtSharedSecret()` with explicit random generator argument.
  try:
    rng.jwtGenSecret.jwtSharedSecret(config)
  except CatchableError:
    return err(jwtCreationError)

proc httpJwtAuth*(key: JwtSharedKey): RpcAuthHook =
  proc handler(req: HttpRequestRef): Future[HttpResponseRef]
         {.gcsafe, async: (raises: [CatchableError]).} =
    let auth = req.headers.getString("Authorization", "?")
    if auth.len < 9 or auth[0..6].cmpIgnoreCase("Bearer ") != 0:
      return await req.respond(Http403, "Missing authorization token")

    let rc = auth[7..^1].strip.verifyTokenHS256(key)
    if rc.isOk:
      return HttpResponseRef(nil)

    debug "Could not authenticate",
      error = rc.error

    case rc.error:
    of jwtTokenValidationError, jwtMethodUnsupported:
      return await req.respond(Http401, "Unauthorized access")
    else:
      return await req.respond(Http403, "Malformed token")

  result = handler

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

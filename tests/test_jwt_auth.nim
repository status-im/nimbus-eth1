# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Test Jwt Authorisation Functionality
## ====================================

import
  std/[base64, json, options, os, strutils, times],
  ../nimbus/config,
  ../nimbus/rpc/jwt_auth,
  ./replay/pp,
  chronicles,
  chronos/apps/http/httpclient as chronoshttpclient,
  chronos/apps/http/httptable,
  eth/[common, keys, p2p],
  nimcrypto/[hmac, utils],
  stew/results,
  stint,
  unittest2,
  graphql,
  graphql/[httpserver, httpclient]

type
  UnGuardedKey =
    array[jwtMinSecretLen,byte]

const
  jwtKeyFile ="jwtsecret.txt"       # external shared secret file
  jwtKeyStripped ="jwtstripped.txt" # without leading 0x
  jwtKeyCopy = jwtSecretFile        # file containing effective data key

  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests" / "test_jwt_auth"]

let
  fakeKey = block:
    var rc: JwtSharedKey
    discard rc.fromHex((0..31).mapIt(15 - (it mod 16)).mapIt(it.byte).toHex)
    rc

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc findFilePath(file: string): Result[string,void] =
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return ok(path)
  err()

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

proc setTraceLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setErrorLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private Functions
# ------------------------------------------------------------------------------

proc fakeGenSecret(fake: JwtSharedKey): JwtGenSecret =
  ## Key random generator, fake version
  result = proc: JwtSharedKey =
    fake

proc base64urlEncode(x: auto): string =
  ## from nimbus-eth2, engine_authentication.nim
  base64.encode(x, safe = true).replace("=", "")

func getIatToken*(time: uint64): JsonNode =
  ## from nimbus-eth2, engine_authentication.nim
  %* {"iat": time}

proc getSignedToken*(key: openArray[byte], payload: string): string =
  ## from nimbus-eth2, engine_authentication.nim
  # Using hard coded string for """{"typ": "JWT", "alg": "HS256"}"""
  let sData = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9." & base64urlEncode(payload)
  sData & "." & sha256.hmac(key, sData).data.base64urlEncode

proc getSignedToken2*(key: openArray[byte], payload: string): string =
  ## Variant of `getSignedToken()`: different algorithm encoding
  let
    jNode = %* {"alg": "HS256", "typ": "JWT" }
    sData = base64urlEncode($jNode) & "." & base64urlEncode(payload)
  sData & "." & sha256.hmac(key, sData).data.base64urlEncode

proc getHttpAuthReqHeader(secret: JwtSharedKey; time: uint64): HttpTable =
  let bearer = secret.UnGuardedKey.getSignedToken($getIatToken(time))
  result.add("aUtHoRiZaTiOn", "Bearer " & bearer)

proc getHttpAuthReqHeader2(secret: JwtSharedKey; time: uint64): HttpTable =
  let bearer = secret.UnGuardedKey.getSignedToken2($getIatToken(time))
  result.add("aUtHoRiZaTiOn", "Bearer " & bearer)

proc createServer(serverAddress: TransportAddress, authHooks: seq[AuthHook] = @[]): GraphqlHttpServerRef =
  let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
  var ctx = GraphqlRef.new()

  const schema = """type Query {name: String}"""
  let r = ctx.parseSchema(schema)
  if r.isErr:
    debugEcho r.error
    return

  let res = GraphqlHttpServerRef.new(
    graphql = ctx,
    address = serverAddress,
    socketFlags = socketFlags,
    authHooks = authHooks
  )

  if res.isErr():
    debugEcho res.error
    return

  res.get()

proc setupClient(address: TransportAddress): GraphqlHttpClientRef =
  GraphqlHttpClientRef.new(address, secure = false).get()

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runKeyLoader(noisy = true;
                  keyFile = jwtKeyFile; strippedFile = jwtKeyStripped) =
  let
    filePath = keyFile.findFilePath.value
    fileInfo = keyFile.splitFile.name.split(".")[0]

    strippedPath = strippedFile.findFilePath.value
    strippedInfo = strippedFile.splitFile.name.split(".")[0]

    dataDir = filePath.splitPath.head
    localKeyFile = dataDir / jwtKeyCopy

    dataDirCmdOpt = &"--data-dir={dataDir}"
    jwtSecretCmdOpt = &"--jwt-secret={filePath}"
    jwtStrippedCmdOpt = &"--jwt-secret={strippedPath}"

  suite "EngineAuth: Load or generate shared secrets":

    test &"Load shared key file {fileInfo}":
      let
        config = @[dataDirCmdOpt,jwtSecretCmdOpt].makeConfig
        secret = fakeKey.fakeGenSecret.jwtSharedSecret(config)
        lines = config.jwtSecret.get.string.readLines(1)

      check secret.isOk
      check 0 < lines.len

      let
        hexKey = "0x" & secret.value.UnGuardedKey.toHex
        hexFake = "0x" & fakeKey.UnGuardedKey.toSeq.toHex
        hexLine = lines[0].strip

      noisy.say "***", "key=", hexKey
      noisy.say "   ", "text=", hexLine
      noisy.say "   ", "fake=", hexFake

      # Compare key against tcontents of shared key file
      check hexKey.cmpIgnoreCase(hexLine) == 0

      # Just to make sure that there was no random generator used
      check hexKey.cmpIgnoreCase(hexFake) != 0

    test &"Load shared key file {strippedInfo}, missing 0x prefix":
      let
        config = @[dataDirCmdOpt,jwtStrippedCmdOpt].makeConfig
        secret = fakeKey.fakeGenSecret.jwtSharedSecret(config)
        lines = config.jwtSecret.get.string.readLines(1)

      check secret.isOk
      check 0 < lines.len

      let
        hexKey = secret.value.UnGuardedKey.toHex
        hexFake = fakeKey.UnGuardedKey.toSeq.toHex
        hexLine = lines[0].strip

      noisy.say "***", "key=", hexKey
      noisy.say "   ", "text=", hexLine
      noisy.say "   ", "fake=", hexFake

      # Compare key against tcontents of shared key file
      check hexKey.cmpIgnoreCase(hexLine) == 0

      # Just to make sure that there was no random generator used
      check hexKey.cmpIgnoreCase(hexFake) != 0

    test &"Generate shared key file, store it in {jwtKeyCopy}":

      # Clean up after file generation
      defer: localKeyFile.removeFile

      # Maybe a stale left over
      localKeyFile.removeFile

      let
        config = @[dataDirCmdOpt].makeConfig
        secret = fakeKey.fakeGenSecret.jwtSharedSecret(config)
        lines = localKeyFile.readLines(1)

      check secret.isOk

      let
        hexKey = "0x" & secret.value.UnGuardedKey.toHex
        hexLine = lines[0].strip

      noisy.say "***", "key=", hexKey
      noisy.say "   ", "text=", hexLine

      # Compare key against tcontents of shared key file
      check hexKey.cmpIgnoreCase(hexLine) == 0

proc runJwtAuth(noisy = true; keyFile = jwtKeyFile) =
  let
    filePath = keyFile.findFilePath.value
    fileInfo = keyFile.splitFile.name.split(".")[0]

    dataDir = filePath.splitPath.head

    dataDirCmdOpt = &"--data-dir={dataDir}"
    jwtSecretCmdOpt = &"--jwt-secret={filePath}"
    config = @[dataDirCmdOpt,jwtSecretCmdOpt].makeConfig

    # The secret is just used for extracting the key, it would otherwise
    # be hidden in the closure of the handler function
    secret = fakeKey.fakeGenSecret.jwtSharedSecret(config)

    # The wrapper contains the handler function with the captured shared key
    authHook = secret.value.httpJwtAuth

  const
    serverAddress = initTAddress("127.0.0.1:8547")
    query = """{ __type(name: "ID") { kind }}"""

  suite "EngineAuth: Http/rpc authentication mechanics":
    let server = createServer(serverAddress, @[authHook])
    server.start()

    test &"JSW/HS256 authentication using shared secret file {fileInfo}":
      # Just to make sure that we made a proper choice. Typically, all
      # ingredients shoud have been tested, already in the preceeding test
      # suite.
      let
        lines = config.jwtSecret.get.string.readLines(1)
        hexKey = "0x" & secret.value.UnGuardedKey.toHex
        hexLine = lines[0].strip
      noisy.say "***", "key=", hexKey
      noisy.say "   ", "text=", hexLine
      check hexKey.cmpIgnoreCase(hexLine) == 0

      let
        time = getTime().toUnix.uint64
        req = secret.value.getHttpAuthReqHeader(time)
      noisy.say "***", "request",
        " Authorization=", req.getString("Authorization")

      setTraceLevel()

      # Run http authorisation request
      let client = setupClient(serverAddress)
      let res = waitFor client.sendRequest(query, req.toList)
      check res.isOk
      if res.isErr:
        noisy.say "***", res.error
        return

      let resp = res.get()
      check resp.status == 200
      check resp.reason == "OK"
      check resp.response == """{"data":{"__type":{"kind":"SCALAR"}}}"""

      setErrorLevel()

    test &"JSW/HS256, ditto with protected header variant":
      let
        time = getTime().toUnix.uint64
        req = secret.value.getHttpAuthReqHeader2(time)

      # Assemble request header
      noisy.say "***", "request",
        " Authorization=", req.getString("Authorization")

      setTraceLevel()

      # Run http authorisation request
      let client = setupClient(serverAddress)
      let res = waitFor client.sendRequest(query, req.toList)
      check res.isOk
      if res.isErr:
        noisy.say "***", res.error
        return

      let resp = res.get()
      check resp.status == 200
      check resp.reason == "OK"
      check resp.response == """{"data":{"__type":{"kind":"SCALAR"}}}"""

      setErrorLevel()

    waitFor server.closeWait()

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc jwtAuthMain*(noisy = defined(debug)) =
  noisy.runKeyLoader
  noisy.runJwtAuth

when isMainModule:
  const
    noisy = defined(debug)

  setErrorLevel()

  noisy.runKeyLoader
  noisy.runJwtAuth

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

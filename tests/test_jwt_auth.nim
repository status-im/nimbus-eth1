# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Test JWT Authorisation Functionality
## ====================================

import
  std/[sequtils, strformat],
  stew/arrayops,
  ../execution_chain/conf,
  ../execution_chain/rpc/jwt_auth,
  ../execution_chain/rpc {.all.},
  chronicles,
  chronos/apps/http/httpclient as chronoshttpclient,
  nimcrypto/[hmac, sha2, utils],
  unittest2,
  websock/websock,
  json_rpc/[rpcserver, rpcclient]

from std/base64 import encode
from std/os import DirSep, fileExists, removeFile, splitFile, splitPath, `/`
from std/times import getTime, toUnix

type UnGuardedKey = array[32,byte]

const
  jwtKeyFile ="jwtsecret.txt"       # external shared secret file
  jwtKeyStripped ="jwtstripped.txt" # without leading 0x
  jwtKeyCopy = jwtSecretFile        # file containing effective data key

  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests" / "test_jwt_auth"]

let
  fakeKey = block:
    var rc: JwtSharedKey
    discard parseJwtSharedKey((0..31).mapIt(15 - (it mod 16)).mapIt(it.byte).toHex)
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

proc say(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

when isMainModule:
  proc setErrorLevel =
    discard
    when defined(chronicles_runtime_filtering) and loggingEnabled:
      setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private Functions
# ------------------------------------------------------------------------------

func fakeGenSecret(fake: JwtSharedKey): Rng =
  ## Key random generator, fake version
  proc(v: var openArray[byte]) =
    discard v.copyFrom(distinctBase fake)

func base64urlEncode(x: auto): string =
  ## from nimbus-eth2, engine_authentication.nim
  base64.encode(x, safe = true).replace("=", "")

func getIatToken(time: uint64): JsonNode =
  ## from nimbus-eth2, engine_authentication.nim
  %* {"iat": time}

func getSignedToken(key: openArray[byte], payload: string): string =
  ## from nimbus-eth2, engine_authentication.nim
  # Using hard coded string for """{"typ": "JWT", "alg": "HS256"}"""
  let sData = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9." & base64urlEncode(payload)
  sData & "." & sha256.hmac(key, sData).data.base64urlEncode

func getHttpAuthReqHeader(secret: JwtSharedKey; time: uint64): HttpTable =
  let bearer = secret.UnGuardedKey.getSignedToken($getIatToken(time))
  result.add("aUtHoRiZaTiOn", "Bearer " & bearer)

# ------------------------------------------------------------------------------
# HTTP combo helpers
# ------------------------------------------------------------------------------

func installRPC(server: RpcServer) =
  server.rpc("rpc_echo") do(input: int) -> string:
    "hello: " & $input

proc setupComboServer(hooks: sink seq[RpcAuthHook]): HttpResult[NimbusHttpServerRef] =
  var handlers: seq[RpcHandlerProc]

  let wsServer = newRpcWebsocketHandler()
  wsServer.installRPC()
  handlers.addHandler(wsServer)

  let rpcServer = newRpcHttpHandler()
  rpcServer.installRPC()
  handlers.addHandler(rpcServer)

  let address = initTAddress("127.0.0.1:0")
  newHttpServerWithParams(address, hooks, handlers)

createRpcSigsFromNim(RpcClient):
  proc rpc_echo(input: int): string

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runKeyLoader(noisy = defined(debug);
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

      # Compare key against contents of shared key file
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

      # Compare key against contents of shared key file
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

      # Compare key against contents of shared key file
      check hexKey.cmpIgnoreCase(hexLine) == 0

proc runJwtAuth(noisy = defined(debug); keyFile = jwtKeyFile) =
  let
    filePath = keyFile.findFilePath.value
    dataDir = filePath.splitPath.head
    dataDirCmdOpt = &"--data-dir={dataDir}"
    jwtSecretCmdOpt = &"--jwt-secret={filePath}"
    config = @[dataDirCmdOpt,jwtSecretCmdOpt].makeConfig

    # The secret is just used for extracting the key, it would otherwise
    # be hidden in the closure of the handler function
    secret = fakeKey.fakeGenSecret.jwtSharedSecret(config)

    # The wrapper contains the handler function with the captured shared key
    authHook = secret.value.httpJwtAuth

  suite "Test combo HTTP server":
    let res = setupComboServer(@[authHook])
    if res.isErr:
      debugEcho res.error
      quit(QuitFailure)

    let
      server = res.get
      time = getTime().toUnix.uint64
      req = secret.value.getHttpAuthReqHeader(time)

    server.start()

    test "RPC query no auth":
      let client = newRpcHttpClient()
      waitFor client.connect("http://" & $server.localAddress)
      try:
        let res = waitFor client.rpc_echo(100)
        discard res
        check false
      except ErrorResponse as exc:
        check exc.msg == "Forbidden"

    test "RPC query with auth":
      proc authHeaders(): seq[(string, string)] =
        req.toList
      let client = newRpcHttpClient(getHeaders = authHeaders)
      waitFor client.connect("http://" & $server.localAddress)
      let res = waitFor client.rpc_echo(100)
      check res == "hello: 100"

    test "ws query no auth":
      let client = newRpcWebSocketClient()
      expect RpcTransportError:
        waitFor client.connect("ws://" & $server.localAddress)

    test "ws query with auth":
      proc authHeaders(): seq[(string, string)] =
        req.toList
      let client = newRpcWebSocketClient(authHeaders)
      waitFor client.connect("ws://" & $server.localAddress)
      let res = waitFor client.rpc_echo(123)
      check res == "hello: 123"

      let res2 = waitFor client.rpc_echo(145)
      check res2 == "hello: 145"

    waitFor server.closeWait()

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

when isMainModule:
  setErrorLevel()

runKeyLoader()
runJwtAuth()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

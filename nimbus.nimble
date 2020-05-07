mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests", "examples"]
# we can't have the result of a custom task in the "bin" var - https://github.com/nim-lang/nimble/issues/542
# bin           = @["build/nimbus"]

requires "nim >= 1.2.0",
  "bncurve",
  "chronicles",
  "chronos",
  "eth",
  "json_rpc",
  "libbacktrace",
  "nimcrypto",
  "stew",
  "stint"

proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, lang = "c") =
  buildBinary name, "tests/", "-d:chronicles_log_level=ERROR"
  exec "build/" & name

task test, "Run tests":
  test "all_tests"
  test "test_rpc"
  test "test_rpc_whisper"

task nimbus, "Build Nimbus":
  buildBinary "nimbus", "nimbus/", "-d:chronicles_log_level=TRACE"

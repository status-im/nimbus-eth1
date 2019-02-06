mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests", "examples"]
# we can't have the result of a custom task in the "bin" var - https://github.com/nim-lang/nimble/issues/542
# bin           = @["build/nimbus"]

requires "nim >= 0.19",
         "chronicles",
         "nimcrypto",
         "stint",
         "json_rpc",
         "chronos",
         "bncurve",
         "eth",
         "std_shims"

proc buildBinary(name: string, srcDir = ".", lang = "c") =
  if not dirExists "build": mkDir "build"
  switch("out", ("./build/" & name))
  setCommand lang, srcDir & name & ".nim"

proc test(name: string, lang = "c") =
  --define:"chronicles_log_level=ERROR"
  --run
  buildBinary name, "tests/"

task test, "Run tests":
  test "all_tests"
  # debugging tools don't yet have tests
  # but they should be compilable
  exec "nim c premix/premix"
  exec "nim c premix/persist"
  exec "nim c premix/debug"
  exec "nim c premix/dumper"
  exec "nim c premix/hunter"

task nimbus, "Build Nimbus":
  buildBinary "nimbus", "nimbus/"


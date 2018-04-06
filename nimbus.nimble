mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 0.18.1",
         "https://github.com/status-im/nim-keccak-tiny.git >= 0.2.0",
         "https://github.com/alehander42/nim-rlp#fix-ordinal", #TODO switching to the Status repo throws: "Error: undeclared identifier: 'Range'"
         "https://github.com/status-im/nim-ttmath#master"

proc test(name: string, lang = "cpp") =
  if not dirExists "build":
    mkDir "build"
  if not dirExists "nimcache":
    mkDir "nimcache"
  --run
  --nimcache: "nimcache"
  switch("out", ("./build/" & name))
  setCommand lang, "tests/" & name & ".nim"

task test, "Run tests":
  test "all_tests"

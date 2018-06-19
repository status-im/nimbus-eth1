mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests", "examples"]

requires "nim >= 0.18.1",
         "nimcrypto",
         "rlp",
         "stint",
         "https://github.com/status-im/nim-eth-common",
         "eth_p2p",
         "eth_keyfile"

proc test(name: string, lang = "c") =
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

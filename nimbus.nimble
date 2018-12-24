mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests", "examples"]
# we can't have the result of a custom task in the "bin" var - https://github.com/nim-lang/nimble/issues/542
# bin           = @["build/nimbus"]

requires "nim >= 0.18.1",
         "chronicles",
         "nimcrypto",
         "rlp",
         "stint",
         "rocksdb",
         "eth_trie",
         "eth_common",
         "json_rpc",
         "asyncdispatch2",
         "eth_p2p",
         "eth_keyfile",
         "eth_keys",
         "eth_bloom",
         "bncurve"

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

task nimbus, "Build Nimbus":
  buildBinary "nimbus", "nimbus/"


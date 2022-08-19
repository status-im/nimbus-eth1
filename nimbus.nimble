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
  "stint",
  "rocksdb",
  "ethash",
  "blscurve",
  "evmc",
  "web3"

binDir = "build"

when declared(namedBin):
  namedBin = {
    "nimbus/nimbus": "nimbus",
    "fluffy/fluffy": "fluffy",
    "fluffy/tools/portalcli": "portalcli",
  }.toTable()

proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(path: string, name: string, params = "", lang = "c") =
  # Verify stack usage is kept low by setting 750k stack limit in tests.
  const stackLimitKiB = 750
  when not defined(windows):
    const (buildOption, runPrefix) = ("", "ulimit -s " & $stackLimitKiB & " && ")
  else:
    # No `ulimit` in Windows.  `ulimit -s` in Bash is accepted but has no effect.
    # See https://public-inbox.org/git/alpine.DEB.2.21.1.1709131448390.4132@virtualbox/
    # Also, the command passed to NimScript `exec` on Windows is not a shell script.
    # Instead, we can set stack size at link time.
    const (buildOption, runPrefix) =
      (" -d:windowsNoSetStack --passL:-Wl,--stack," & $(stackLimitKiB * 1024), "")

  buildBinary name, (path & "/"), params & buildOption
  exec runPrefix & "build/" & name

task test, "Run tests":
  test "tests", "all_tests", "-d:chronicles_log_level=ERROR -d:unittest2DisableParamFiltering"

task test_rocksdb, "Run rocksdb tests":
  test "tests/db", "test_kvstore_rocksdb", "-d:chronicles_log_level=ERROR -d:unittest2DisableParamFiltering"

task fluffy, "Build fluffy":
  buildBinary "fluffy", "fluffy/", "-d:chronicles_log_level=TRACE -d:chronosStrictException -d:PREFER_BLST_SHA256=false"

task fluffy_tools, "Build fluffy tools":
  buildBinary "portalcli", "fluffy/tools/", "-d:chronicles_log_level=TRACE -d:chronosStrictException -d:PREFER_BLST_SHA256=false"
  buildBinary "blockwalk", "fluffy/tools/", "-d:chronicles_log_level=TRACE -d:chronosStrictException"
  buildBinary "eth_data_exporter", "fluffy/tools/", "-d:chronicles_log_level=TRACE -d:chronosStrictException -d:PREFER_BLST_SHA256=false"

task utp_test_app, "Build uTP test app":
  buildBinary "utp_test_app", "fluffy/tools/utp_testing/", "-d:chronicles_log_level=TRACE -d:chronosStrictException"

task utp_test, "Run uTP integration tests":
  test "fluffy/tools/utp_testing", "utp_test", "-d:chronicles_log_level=ERROR -d:chronosStrictException"

task test_portal_testnet, "Build test_portal_testnet":
  buildBinary "test_portal_testnet", "fluffy/scripts/", "-d:chronicles_log_level=DEBUG -d:chronosStrictException -d:unittest2DisableParamFiltering -d:PREFER_BLST_SHA256=false"

task testfluffy, "Run fluffy tests":
  # Need the nimbus_db_backend in state network tests as we need a Hexary to
  # start from, even though it only uses the MemoryDb.
  test "fluffy/tests", "all_fluffy_tests", "-d:chronicles_log_level=ERROR -d:chronosStrictException -d:nimbus_db_backend=sqlite -d:PREFER_BLST_SHA256=false"

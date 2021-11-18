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

task nimbus, "Build Nimbus":
  buildBinary "nimbus", "nimbus/", "-d:chronicles_log_level=TRACE"

task fluffy, "Build fluffy":
  buildBinary "fluffy", "fluffy/", "-d:chronicles_log_level=TRACE -d:chronosStrictException"

task portalcli, "Build portalcli":
  buildBinary "portalcli", "fluffy/tools/", "-d:chronicles_log_level=TRACE -d:chronosStrictException"

task testfluffy, "Run fluffy tests":
  # Need the nimbus_db_backend in state network tests as we need a Hexary to
  # start from, even though it only uses the MemoryDb.
  test "fluffy/tests", "all_fluffy_tests", "-d:chronicles_log_level=ERROR -d:chronosStrictException -d:nimbus_db_backend=sqlite"

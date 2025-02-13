# nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests", "examples"]
# we can't have the result of a custom task in the "bin" var - https://github.com/nim-lang/nimble/issues/542
# bin           = @["build/nimbus"]

requires "nim >= 1.6.0",
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
  "web3",
  "minilru"

binDir = "build"

when declared(namedBin):
  namedBin = {
    "execution_chain/nimbus_execution_client": "nimbus_execution_client",
    "portal/client/nimbus_portal_client": "nimbus_portal_client",
    "nimbus_verified_proxy/nimbus_verified_proxy": "nimbus_verified_proxy",
  }.toTable()

import std/[os, strutils]

proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(path: string, name: string, params = "", lang = "c") =
  # Verify stack usage is kept low by setting 1mb stack limit in tests.
  const stackLimitKiB = 1024
  when not defined(windows):
    const (buildOption, runPrefix) = ("", "ulimit -s " & $stackLimitKiB & " && ")
  else:
    # No `ulimit` in Windows.  `ulimit -s` in Bash is accepted but has no effect.
    # See https://public-inbox.org/git/alpine.DEB.2.21.1.1709131448390.4132@virtualbox/
    # Also, the command passed to NimScript `exec` on Windows is not a shell script.
    # Instead, we can set stack size at link time.
    const (buildOption, runPrefix) =
      (" -d:windowsNoSetStack --passL:-Wl,--stack," & $(stackLimitKiB * 2048), "")

  buildBinary name, (path & "/"), params & buildOption
  exec runPrefix & "build/" & name

task test, "Run tests":
  test "tests", "all_tests", "-d:chronicles_log_level=ERROR"

task test_import, "Run block import test":
  let tmp = getTempDir() / "nimbus-eth1-block-import"
  if dirExists(tmp):
    echo "Remove directory before running test: " & tmp
    quit(QuitFailure)

  const nimbus_exec_client = when defined(windows):
    "build/nimbus_execution_client.exe"
  else:
    "build/nimbus_execution_client"

  if not fileExists(nimbus_exec_client):
    echo "Build nimbus execution client before running this test"
    quit(QuitFailure)

  # Test that we can resume import
  exec "build/nimbus_execution_client import --data-dir:" & tmp & " --era1-dir:tests/replay --max-blocks:1"
  exec "build/nimbus_execution_client import --data-dir:" & tmp & " --era1-dir:tests/replay --max-blocks:1023"
  # There should only be 8k blocks
  exec "build/nimbus_execution_client import --data-dir:" & tmp & " --era1-dir:tests/replay --max-blocks:10000"

task test_evm, "Run EVM tests":
  test "tests", "evm_tests", "-d:chronicles_log_level=ERROR -d:unittest2DisableParamFiltering"

## Portal tasks

task nimbus_portal_client, "Build nimbus_portal_client":
  buildBinary "nimbus_portal_client", "portal/client/", "-d:chronicles_log_level=TRACE"

task portal_test, "Run Portal tests":
  test "portal/tests/history_network_tests/", "all_history_network_custom_chain_tests", "-d:chronicles_log_level=ERROR"
  # Seperate build for these tests as they are run with a low `mergeBlockNumber`
  # to make the tests faster. Using the real mainnet merge block number is not
  # realistic for these tests.
  test "portal/tests", "all_portal_tests", "-d:chronicles_log_level=ERROR -d:mergeBlockNumber:38130"

task utp_test_app, "Build uTP test app":
  buildBinary "utp_test_app", "portal/tools/utp_testing/", "-d:chronicles_log_level=TRACE"

task utp_test, "Run uTP integration tests":
  test "portal/tools/utp_testing", "utp_test", "-d:chronicles_log_level=ERROR"

task test_portal_testnet, "Build test_portal_testnet":
  buildBinary "test_portal_testnet", "portal/scripts/", "-d:chronicles_log_level=DEBUG -d:unittest2DisableParamFiltering"

## Nimbus Verified Proxy tasks

task nimbus_verified_proxy, "Build Nimbus verified proxy":
  buildBinary "nimbus_verified_proxy", "nimbus_verified_proxy/", "-d:chronicles_log_level=TRACE"

task nimbus_verified_proxy_test, "Run Nimbus verified proxy tests":
  test "nimbus_verified_proxy/tests", "all_proxy_tests", "-d:chronicles_log_level=ERROR"

task build_fuzzers, "Build fuzzer test cases":
  # This file is there to be able to quickly build the fuzzer test cases in
  # order to avoid bit rot (e.g. for CI). Not for actual fuzzing.
  # TODO: Building fuzzer test case one by one will make it take a bit longer,
  # but we cannot import them in one Nim file due to the usage of
  # `exportc: "AFLmain"` in the fuzzing test template for Windows:
  # https://github.com/status-im/nim-testutils/blob/master/testutils/fuzzing.nim#L100
  for file in walkDirRec("tests/networking/fuzzing/"):
    if file.endsWith("nim"):
      exec "nim c -c -d:release " & file
## nimbus tasks

task nimbus, "Build Nimbus":
  buildBinary "nimbus", "nimbus/", "-d:chronicles_log_level=TRACE"

task nimbus_test, "Run Nimbus tests":
  test "nimbus/tests/","all_tests", "-d:chronicles_log_level=ERROR"

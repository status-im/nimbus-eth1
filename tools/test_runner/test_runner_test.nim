# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, os, osproc, strutils],
  unittest2

const testData = "tools/test_runner/testdata"

suite "test_runner":
  # The runner rebuilds the fixture's JSON access list to compare it with the
  # header and drops it on a mismatch, after which the block still passes. Only
  # the executor it reports shows whether the list was delivered.
  test "blocktest delivers a valid fixture's access list to the parallel executor":
    let (output, exitCode) = execCmdEx(
      "build" / "test_runner" & " blocktest --bal-report " & testData / "blocktest_bal.json"
    )
    var events: seq[JsonNode]
    for line in output.splitLines():
      if line.startsWith("{\"event\""):
        events.add parseJson(line)
    check:
      exitCode == QuitSuccess
      events.len == 1
    if events.len == 1:
      check:
        events[0]["path"].getStr() == "parallel"
        events[0]["reason"].getStr() == ""

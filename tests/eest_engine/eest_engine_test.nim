# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[os, osproc],
  unittest2

const
  baseFolder = "tests/fixtures/eest/engine_tests"

proc runTest(appDir: string, spec: string): bool =
  try:
    let
      cmd  = appDir / "eest_engine " & spec
      exitCode = execCmd(cmd)

    exitCode == QuitSuccess
  except OSError as exc:
    debugEcho "Something went wrong: ", exc.msg
    false

const skipFiles = [
  "CALLBlake2f_MaxRounds.json",
  ]

let appDir = getAppDir()
for fileName in walkDirRec(baseFolder):
  let last = fileName.splitPath().tail
  if last in skipFiles:
    continue
  test last:
    let res = runTest(appDir, fileName)
    if not res:
      debugEcho fileName.splitPath().tail
    check res

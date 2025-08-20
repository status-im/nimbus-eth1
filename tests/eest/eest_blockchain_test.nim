# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, osproc],
  unittest2

const
  baseFolder = "tests/fixtures"
  eestType = "blockchain_tests"
  eestReleases = [
    "eest_develop",
    # baseFolder / "eest_static" / eestType,
    "eest_stable",
    "eest_devnet"
  ]

proc runTest(appDir: string, spec: string): bool =
  try:
    let
      cmd  = appDir / "eest_blockchain " & spec
      exitCode = execCmd(cmd)

    exitCode == QuitSuccess
  except OSError as exc:
    debugEcho "Something went wrong: ", exc.msg
    false

const skipFiles = [
    ""
]

let appDir = getAppDir()
for eest in eestReleases:
  suite eest:
    for fileName in walkDirRec(baseFolder / eest / eestType):
      let last = fileName.splitPath().tail
      if last in skipFiles:
        continue
      test last:
        let res = runTest(appDir, fileName)
        if not res:
          debugEcho fileName.splitPath().tail
        check res
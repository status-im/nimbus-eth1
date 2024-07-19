# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, osproc, strutils, tables],
  unittest2,
  testutils/markdown_reports,
  ../../tests/test_allowed_to_fail

type
  StatusMap = OrderedTable[string, OrderedTable[string, Status]]
  TestFile = object
    fullPath: string
    dispName: string

const
  inputFolder = "tests/fixtures/eth_tests/GeneralStateTests"
  #inputFolder = "tests/fixtures/eth_tests/EIPTests/StateTests"
  testData = "tools/evmstate/testdata"

proc runTest(filename: string): bool =
  let appDir = getAppDir()
  let cmd = appDir / ("evmstate " & filename)
  let (res, exitCode) = execCmdEx(cmd)
  if exitCode != QuitSuccess:
    echo res
    return false

  true

template skipTest(folder, name: untyped): bool =
  skipNewGSTTests(folder, name)

proc collectFileNames(
    inputPath: string, map: var StatusMap, fileNames: var seq[TestFile]
) =
  for fileName in walkDirRec(inputPath):
    if not fileName.endsWith(".json"):
      continue

    let (folder, name) = fileName.splitPath()
    let last = folder.splitPath().tail
    if not map.hasKey(last):
      map[last] = initOrderedTable[string, Status]()
    map[last][name] = Status.Skip
    if skipTest(last, name):
      continue

    fileNames.add TestFile(
      fullPath: fileName, dispName: substr(fileName, inputPath.len + 1)
    )

proc main() =
  suite "evmstate test suite":
    var status = initOrderedTable[string, OrderedTable[string, Status]]()
    var filenames: seq[TestFile] = @[]
    collectFileNames(testData, status, filenames)
    collectFileNames(inputFolder, status, filenames)

    for filename in filenames:
      let input = filename
      test input.dispName:
        let (folder, name) = input.fullPath.splitPath()
        let last = folder.splitPath().tail
        status[last][name] = Status.Fail
        let res = runTest(input.fullPath)
        check true == res
        if res:
          status[last][name] = Status.OK

    status.sort do(
      a: (string, OrderedTable[string, Status]),
      b: (string, OrderedTable[string, Status])
    ) -> int:
      cmp(a[0], b[0])

    generateReport("evmstate", status)

main()

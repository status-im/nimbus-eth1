import
  std/[os, osproc, strutils, tables],
  unittest2,
  testutils/markdown_reports,
  ../../tests/test_allowed_to_fail

const
  inputFolder = "tests" / "fixtures" / "eth_tests" / "GeneralStateTests"

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

proc main() =
  suite "evmstate test suite":
    var status = initOrderedTable[string, OrderedTable[string, Status]]()
    var filenames: seq[string] = @[]
    for filename in walkDirRec(inputFolder):
      if not filename.endsWith(".json"):
        continue

      let (folder, name) = filename.splitPath()
      let last = folder.splitPath().tail
      if not status.hasKey(last):
        status[last] = initOrderedTable[string, Status]()
      status[last][name] = Status.Skip
      if skipTest(last, name):
        continue

      filenames.add filename

    for inputFile in filenames:
      let testName = substr(inputFile, inputFolder.len+1)
      test testName:
        let (folder, name) = inputFile.splitPath()
        let last = folder.splitPath().tail
        status[last][name] = Status.Fail
        let res = runTest(inputFile)
        check true == res
        if res:
          status[last][name] = Status.OK

    status.sort do (a: (string, OrderedTable[string, Status]),
                    b: (string, OrderedTable[string, Status])) -> int: cmp(a[0], b[0])

    generateReport("evmstate", status)

main()

# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import std/[os, osproc, strutils, json, streams], unittest2

type TestFile = object
  fullPath: string
  dispName: string

const testData = "tools" / "txparse" / "testdata"

proc runTest(n: JsonNode): bool =
  let
    appDir = getAppDir()
    cmd = appDir / "txparse"
    input = n["input"].getStr
    p = startProcess(cmd, options = {poStdErrToStdOut, poUsePath, poEvalCommand})
    inp = inputStream(p)
    outp = outputStream(p)

  inp.write(input)
  inp.close()

  var
    exitCode = -1
    line = newStringOfCap(120)
    res = ""

  while true:
    if outp.readLine(line):
      res.add(line)
      res.add("\n")
    else:
      exitCode = peekExitCode(p)
      if exitCode != -1:
        break

  close(p)

  if exitCode != QuitSuccess:
    echo "txparse execution error: ", res
    return false

  let mustError = n["error"].getBool
  if mustError:
    if "err:" notin res:
      echo "txparse result error: ", res
      return false
  else:
    let cleanRes = strip(res)
    if not cleanRes.startsWith("0x") and cleanRes.len != 42:
      echo "txparse result error: ", res
      return false

  true

proc runTest(fileName: string): bool =
  let n = json.parseFile(fileName)
  result = true
  for x in n:
    let res = runTest(x)
    result = result and res

proc collectFileNames(inputPath: string, fileNames: var seq[TestFile]) =
  for filename in walkDirRec(inputPath):
    if not fileName.endsWith(".json"):
      continue

    fileNames.add TestFile(
      fullPath: filename, dispName: substr(filename, inputPath.len + 1)
    )

proc main() =
  suite "txparse test suite":
    var filenames: seq[TestFile] = @[]
    collectFileNames(testData, filenames)

    for input in filenames:
      test input.dispName:
        let res = runTest(input.fullPath)
        check true == res

main()

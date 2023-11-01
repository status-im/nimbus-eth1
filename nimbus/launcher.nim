# Nimbus
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import os, osproc, json

when defined(windows):
  const
    premixExecutable = "premix.exe"
    browserLauncher = "cmd /c start"
elif defined(macos):
  const
    premixExecutable = "premix"
    browserLauncher = "open"
else:
  const
    premixExecutable = "premix"
    browserLauncher = "xdg-open"

proc getFileDir*(file: string): string =
  var searchDirs = [
    "." ,
    "." / "build" ,
    "." / "premix"
  ]

  for dir in searchDirs:
    if fileExists(dir / file):
      return dir

  result = ""

proc getFilePath(file: string): string =
  let dir = getFileDir(file)
  if dir.len > 0:
    return dir / file
  else:
    return ""

proc launchPremix*(fileName: string, metaData: JsonNode) =
  let premixExe = getFilePath(premixExecutable)

  writeFile(fileName, metaData.pretty)

  if premixExe.len > 0:
    if execCmd(premixExe & " " & fileName) == 0:
      if execCmd(browserLauncher & " " & getFilePath("index.html")) != 0:
        echo "failed to launch default browser"
    else:
      echo "failed to execute the premix debugging tool"


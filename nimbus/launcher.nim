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

proc getPremixDir(): (bool, string) =
  var premixDir = [
    "." ,
    ".." & DirSep & "premix"
  ]

  for c in premixDir:
    if fileExists(c & DirSep & premixExecutable):
      return (true, c)

  result = (false, ".")

proc launchPremix*(fileName: string, metaData: JsonNode) =
  let
    (premixAvailable, premixDir) = getPremixDir()
    premixExe = premixDir & DirSep & premixExecutable

  writeFile(premixDir & DirSep & fileName, metaData.pretty)

  if premixAvailable:
    if execCmd(premixExe & " " & premixDir & DirSep & fileName) == 0:
      if execCmd(browserLauncher & " " & premixDir & DirSep & "index.html") != 0:
        echo "failed to launch default browser"
    else:
      echo "failed to execute premix debugging tool"

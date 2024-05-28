# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils, os, sequtils],
  stew/byteutils

const
  sourcePath  = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  nimbusRevision {.strdefine.} = "00000000"

static:
  doAssert(nimbusRevision.len == 8, "nimbusRevision must be consist of 8 characters")
  doAssert(nimbusRevision.allIt(it in HexDigits), "nimbusRevision should contains only hex chars")

proc gitFolderExists(path: string): bool {.compileTime.} =
  # walk up parent folder to find `.git` folder
  var prevPath = sourcePath
  while true:
    if dirExists(prevPath & "/.git"):
      return true
    let parts = splitPath(prevPath)
    if parts.tail.len == 0: break
    prevPath = parts.head
  false

const
  NimbusName* = "nimbus-eth1"
  ## project name string

  NimbusMajor*: int = 0
  ## is the major number of Nimbus' version.

  NimbusMinor*: int = 1
  ## is the minor number of Nimbus' version.

  NimbusPatch*: int = 0
  ## is the patch number of Nimbus' version.

  NimbusVersion* = $NimbusMajor & "." & $NimbusMinor & "." & $NimbusPatch
  ## is the version of Nimbus as a string.

  # strip: remove spaces
  # --short=8: ensure we get 8 chars of commit hash
  # -C sourcePath: get the correct git hash no matter where the current dir is.
  GitRevision* = if gitFolderExists(sourcePath):
                   # only using git if the parent dir is a git repo.
                   strip(staticExec("git -C " & sourcePath & " rev-parse --short=8 HEAD"))
                 else:
                   # otherwise we use revision number given by build system.
                   # e.g. user download from release tarball, or Github zip download.
                   nimbusRevision

  GitRevisionBytes* = hexToByteArray[4](GitRevision)

  NimVersion* = "Nim Version " & $NimMajor & "." & $NimMinor & "." & $NimPatch

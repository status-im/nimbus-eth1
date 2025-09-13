# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[os, strutils, strformat],
  stew/byteutils,
  ./compile_info,
  ./version

export version

# TODO: Unify and use the buildinfo from nimbus-eth2
# For that it needs to be shifted to a template which takes in the
# source path of nimbus-eth1 as an input
const sourcePath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

proc gitFolderExists(path: string): bool {.compileTime.} =
  # walk up parent folder to find `.git` folder
  var currPath = sourcePath
  while true:
    if dirExists(currPath & "/.git"):
      return true
    let parts = splitPath(currPath)
    if parts.tail.len == 0:
      break
    currPath = parts.head
  false

const
  NimbusName* = "nimbus-eth1"
  ## project name string

  GitRevisionOverride {.strdefine.} = ""

  GitRevision* =
    when GitRevisionOverride.len > 0:
      static:
        doAssert(
          GitRevisionOverride.len == 8,
          "GitRevisionOverride must consist of 8 characters",
        )
        doAssert(
          GitRevisionOverride.allIt(it in HexDigits),
          "GitRevisionOverride should contains only hex chars",
        )

      GitRevisionOverride
    else:
      if gitFolderExists(sourcePath):
        # only using git if the parent dir is a git repo.
        strip(
          staticExec(
            "git -C " & strutils.escape(sourcePath) & " rev-parse --short=8 HEAD"
          )
        )
      else:
        # otherwise we use revision number given by build system.
        # e.g. user download from release tarball, or Github zip download.
        "00000000"

  # Please keep it 4 bytes long, used in `engine_ClientVersionV1`
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/identification.md#clientversionv1
  GitRevisionBytes* = hexToByteArray[4](GitRevision)

  FullVersionStr* = "v" & NimbusVersion & "-" & GitRevision

  ClientId* = &"{NimbusName}/{FullVersionStr}/{hostOS}-{hostCPU}/Nim-{NimVersion}"

  ShortClientId* = NimbusName & "/" & FullVersionStr

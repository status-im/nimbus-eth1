# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  strutils,
  stew/byteutils

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

  # In the Github Actions CI, different OS can give
  # different result if using their default configuration.
  # `git rev-parse HEAD` or `git rev-parse --short HEAD`
  # So we use --short=8 to make them all produce the same 4 bytes commit hash
  GitRevisionString* = strip(staticExec("git rev-parse --short=8 HEAD"))

  GitRevisionBytes* = hexToByteArray[4](GitRevisionString)

  GitRevision* = GitRevisionString[0..5]

  NimVersion* = staticExec("nim --version | grep Version")

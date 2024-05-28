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

  # strip    : remove spaces
  # --short=8: ensure we get 8 chars of commit hash
  # [0..7]   : remove trailing chars(e.g. on Github Windows CI)
  GitRevision* = strip(staticExec("git rev-parse --short=8 HEAD"))[0..7]

  GitRevisionBytes* = hexToByteArray[4](GitRevision)

  NimVersion* = staticExec("nim --version | grep Version")

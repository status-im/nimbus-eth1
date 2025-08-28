# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[strformat],
  stew/byteutils, ./compile_info, beacon_chain/buildinfo

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

  GitRevisionBytes* = hexToByteArray[4](GitRevision)

  FullVersionStr* = "v" & NimbusVersion & "-" & GitRevision

  ClientId* = &"{NimbusName}/{FullVersionStr}/{hostOS}-{hostCPU}/Nim-{NimVersion}"

  ShortClientId* = NimbusName & "/" & FullVersionStr

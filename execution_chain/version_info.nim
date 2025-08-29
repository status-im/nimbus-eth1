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
  stew/byteutils, ./compile_info, beacon_chain/buildinfo,
  ./version

export
  version

const
  NimbusName* = "nimbus-eth1"
  ## project name string

  GitRevisionBytes* = hexToByteArray[4](GitRevision)

  FullVersionStr* = "v" & NimbusVersion & "-" & GitRevision

  ClientId* = &"{NimbusName}/{FullVersionStr}/{hostOS}-{hostCPU}/Nim-{NimVersion}"

  ShortClientId* = NimbusName & "/" & FullVersionStr

# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[os, strutils, strformat],
  metrics,
  stew/byteutils,
  beacon_chain/buildinfo,
  ./compile_info,
  ./version

export version

declareGauge nec_version,
  "Nimbus execution client version info (as metric labels)",
  ["version", "commit"], name = "nec_version"

const
  NimbusName* = "Nimbus"
  ## project name string

  #GitRevisionOverride {.strdefine.} = ""
  sourcePath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

  GitRevision* = generateGitRevision(sourcePath)

  # Please keep it 4 bytes long, used in `engine_ClientVersionV1`
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/identification.md#clientversionv1
  GitRevisionBytes* = hexToByteArray[4](GitRevision)

  FullVersionStr* = "v" & NimbusVersion & "-" & GitRevision

  CpuInfo* = &"{hostOS}-{hostCPU}/Nim-{NimVersion}"

  ClientId* = &"{NimbusName}/{FullVersionStr}/{CpuInfo}"

  ShortClientId* = NimbusName & "/" & FullVersionStr

nec_version.set(1, labelValues = [FullVersionStr, GitRevision])

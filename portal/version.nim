# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[os, strutils],
  stew/byteutils,
  metrics,
  beacon_chain/buildinfo,
  ../execution_chain/version

export buildinfo

const
  sourcePath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  GitRevision = generateGitRevision(sourcePath)

  fullVersionStr* = "v" & NimbusVersion & "-" & GitRevision

  clientName* = "nimbus_portal_client"

  # The web3_clientVersion
  clientVersion* =
    clientName & "/" & fullVersionStr & "/" & hostOS & "-" & hostCPU & "/" & "Nim" &
    NimVersion

  copyrightBanner* =
    "Copyright (c) 2021-" & compileYear & " Status Research & Development GmbH"

  # Short debugging identifier to be placed in the ENR
  # Note: This got replaced by the ping extension containing the client_info.
  # Once no longer used it can be deprecated.
  enrClientInfoShort* = toBytes("n")

declareGauge versionGauge,
  "nimbus_portal_client version info (as metric labels)",
  ["version", "commit"],
  name = "nimbus_portal_client_version"
versionGauge.set(1, labelValues = [fullVersionStr, GitRevision])

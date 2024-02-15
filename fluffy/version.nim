# Nimbus fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  stew/byteutils,
  metrics

const
  versionMajor* = 0
  versionMinor* = 1
  versionBuild* = 0

  gitRevision* = strip(staticExec("git rev-parse --short HEAD"))[0..5]

  versionAsStr* =
    $versionMajor & "." & $versionMinor & "." & $versionBuild

  fullVersionStr* = "v" & versionAsStr & "-" & gitRevision

  clientName* = "fluffy"

  nimFullBanner = staticExec("nim --version")
  nimBanner* = staticExec("nim --version | grep Version")

  # The web3_clientVersion
  clientVersion* = clientName & "/" &
      fullVersionStr & "/" &
      hostOS & "-" & hostCPU & "/" &
      "Nim" & NimVersion

  compileYear = CompileDate[0 ..< 4]  # YYYY-MM-DD (UTC)
  copyrightBanner* =
    "Copyright (c) 2021-" & compileYear & " Status Research & Development GmbH"

  # Short debugging identifier to be placed in the ENR
  enrClientInfoShort* = toBytes("f")

func getNimGitHash*(): string =
  const gitPrefix = "git hash: "
  let tmp = splitLines(nimFullBanner)
  if tmp.len == 0:
    return
  for line in tmp:
    if line.startsWith(gitPrefix) and line.len > 8 + gitPrefix.len:
      result = line[gitPrefix.len..<gitPrefix.len + 8]

# TODO: Currently prefixing these metric names as the non prefixed names give
# a collector already registered conflict at runtime. This is due to the same
# names in nimbus-eth2 nimbus_binary_common.nim even though there are no direct
# imports of that file.

declareGauge versionGauge,"Fluffy version info (as metric labels)",
  ["version", "commit"], name = "fluffy_version"
versionGauge.set(1, labelValues = [fullVersionStr, gitRevision])

declareGauge nimVersionGauge, "Nim version info",
  ["version", "nim_commit"], name = "fluffy_nim_version"
nimVersionGauge.set(1, labelValues = [NimVersion, getNimGitHash()])

# Nimbus fluffy
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import strutils

const
  versionMajor* = 0
  versionMinor* = 1
  versionBuild* = 0

  gitRevision* = strip(staticExec("git rev-parse --short HEAD"))[0..5]

  versionAsStr* =
    $versionMajor & "." & $versionMinor & "." & $versionBuild

  fullVersionStr* = "v" & versionAsStr & "-" & gitRevision

  clientName* = "fluffy"

  nimVersion* = staticExec("nim --version | grep -oP '[0-9]+\\.[0-9]+\\.[0-9]+'")

  # The web3_clientVersion
  clientVersion* = clientName & "/" &
      fullVersionStr & "/" &
      hostOS & "-" & hostCPU & "/" &
      "Nim" & nimVersion

# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  ssz_serialization,
  eth/p2p/discoveryv5/[enr, node],
  ../../common/common_types

export ssz_serialization

type PortalVersionValue* = List[uint8, 8]

const
  portalVersionKey* = "pv"
  localSupportedVersions* = PortalVersionValue(@[0'u8, 1'u8])

func getPortalVersions(record: Record): Result[PortalVersionValue, string] =
  let valueBytes = record.get(portalVersionKey, seq[byte]).valueOr:
    return ok(PortalVersionValue(@[0'u8]))

  decodeSsz(valueBytes, PortalVersionValue)

func highestCommonPortalVersion(
    versions: PortalVersionValue, supportedVersions: PortalVersionValue
): Result[uint8, string] =
  let commonVersions = versions.filterIt(supportedVersions.contains(it))
  if commonVersions.len == 0:
    return err("No common protocol versions found")

  ok(max(commonVersions))

func highestCommonPortalVersion*(
    record: Record, supportedVersions: PortalVersionValue
): Result[uint8, string] =
  let versions = ?record.getPortalVersions()
  versions.highestCommonPortalVersion(supportedVersions)

func highestCommonPortalVersion*(
    node: Node, supportedVersions: PortalVersionValue
): Result[uint8, string] =
  node.record.highestCommonPortalVersion(supportedVersions)

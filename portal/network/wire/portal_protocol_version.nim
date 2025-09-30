# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/rlp,
  eth/p2p/discoveryv5/[node],
  eth/common/base_rlp,
  ../../common/common_types

export base_rlp

type PortalEnrField* = object
  pvMin: uint8
  pvMax: uint8
  chainId: ChainId

const
  portalEnrKey* = "p"
  localSupportedVersionMin* = 2'u8
  localSupportedVersionMax* = 2'u8
  localChainId* = 1.chainId() # Mainnet by default, TODO: runtime configuration
  localPortalEnrField* = PortalEnrField(
    pvMin: localSupportedVersionMin,
    pvMax: localSupportedVersionMax,
    chainId: localChainId,
  )

func init*(T: type PortalEnrField, pvMin: uint8, pvMax: uint8, chainId: ChainId): T =
  T(pvMin: pvMin, pvMax: pvMax, chainId: chainId)

func getPortalEnrField(record: Record): Result[PortalEnrField, string] =
  let valueBytes = record.get(portalEnrKey, seq[byte]).valueOr:
    # When no field, default to version 0 and mainnet chainId
    return ok(PortalEnrField(pvMin: 0'u8, pvMax: 0'u8, chainId: 1.chainId()))

  let portalField = decodeRlp(valueBytes, PortalEnrField).valueOr:
    return err("Failed to decode Portal field: " & error)

  if portalField.pvMin > portalField.pvMax:
    return err("Invalid Portal ENR field: minimum version > maximum version")

  ok(portalField)

func highestCommonPortalVersionAndChain(
    a: PortalEnrField, b: PortalEnrField
): Result[uint8, string] =
  if a.chainId != b.chainId:
    return err("ChainId mismatch: remote=" & $a.chainId & ", local=" & $b.chainId)

  let
    commonMin = max(a.pvMin, b.pvMin)
    commonMax = min(a.pvMax, b.pvMax)

  if commonMin > commonMax:
    return err("No common Portal wire protocol version found")

  ok(commonMax)

func highestCommonPortalVersionAndChain*(
    record: Record, supportedPortalField: PortalEnrField
): Result[uint8, string] =
  ## Return highest common portal protocol version of both ENRs, but only if chainIds match
  let portalField = ?record.getPortalEnrField()
  portalField.highestCommonPortalVersionAndChain(supportedPortalField)

func highestCommonPortalVersionAndChain*(
    node: Node, supportedPortalField: PortalEnrField
): Result[uint8, string] =
  ## Return highest common portal protocol version of both nodes, but only if chainIds match
  node.record.highestCommonPortalVersionAndChain(supportedPortalField)

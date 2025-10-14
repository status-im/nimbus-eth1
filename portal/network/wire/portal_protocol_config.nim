# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  confutils,
  chronos,
  stint,
  stew/byteutils,
  eth/p2p/discoveryv5/routing_table,
  ./portal_protocol_version

type
  PortalNetwork* = enum
    none
    mainnet

  # The Portal sub-protocols
  PortalSubnetwork* = enum
    history
    beacon

  PortalProtocolId* = array[2, byte]

  RadiusConfigKind* = enum
    Static
    Dynamic

  RadiusConfig* = object
    case kind*: RadiusConfigKind
    of Static:
      logRadius*: uint16
    of Dynamic:
      discard

  PortalProtocolConfig* = object
    tableIpLimits*: TableIpLimits
    bitsPerHop*: int
    alpha*: int
    radiusConfig*: RadiusConfig
    disablePoke*: bool
    maxGossipNodes*: int
    contentCacheSize*: int
    disableContentCache*: bool
    offerCacheSize*: int
    disableOfferCache*: bool
    maxConcurrentOffers*: int
    disableBanNodes*: bool
    radiusCacheSize*: int

const
  defaultRadiusConfig* = RadiusConfig(kind: Dynamic)
  defaultRadiusConfigDesc* = $defaultRadiusConfig.kind
  defaultDisablePoke* = false
  defaultMaxGossipNodes* = 4
  defaultContentCacheSize* = 128
  defaultDisableContentCache* = false
  defaultOfferCacheSize* = 1024
  defaultDisableOfferCache* = false
  defaultMaxConcurrentOffers* = 100
  defaultAlpha* = 3
  revalidationTimeout* = chronos.seconds(30)
  defaultDisableBanNodes* = true
  defaultRadiusCacheSize* = 512

  defaultPortalProtocolConfig* = PortalProtocolConfig(
    tableIpLimits: DefaultTableIpLimits,
    bitsPerHop: DefaultBitsPerHop,
    alpha: defaultAlpha,
    radiusConfig: defaultRadiusConfig,
    disablePoke: defaultDisablePoke,
    maxGossipNodes: defaultMaxGossipNodes,
    contentCacheSize: defaultContentCacheSize,
    disableContentCache: defaultDisableContentCache,
    offerCacheSize: defaultOfferCacheSize,
    disableOfferCache: defaultDisableOfferCache,
    maxConcurrentOffers: defaultMaxConcurrentOffers,
    disableBanNodes: defaultDisableBanNodes,
    radiusCacheSize: defaultRadiusCacheSize,
  )

proc init*(
    T: type PortalProtocolConfig,
    tableIpLimit: uint,
    bucketIpLimit: uint,
    bitsPerHop: int,
    alpha: int,
    radiusConfig: RadiusConfig,
    disablePoke: bool,
    maxGossipNodes: int,
    contentCacheSize: int,
    disableContentCache: bool,
    offerCacheSize: int,
    disableOfferCache: bool,
    maxConcurrentOffers: int,
    disableBanNodes: bool,
    radiusCacheSize: int,
): T =
  PortalProtocolConfig(
    tableIpLimits:
      TableIpLimits(tableIpLimit: tableIpLimit, bucketIpLimit: bucketIpLimit),
    bitsPerHop: bitsPerHop,
    alpha: alpha,
    radiusConfig: radiusConfig,
    disablePoke: disablePoke,
    maxGossipNodes: maxGossipNodes,
    contentCacheSize: contentCacheSize,
    disableContentCache: disableContentCache,
    offerCacheSize: offerCacheSize,
    disableOfferCache: disableOfferCache,
    maxConcurrentOffers: maxConcurrentOffers,
    disableBanNodes: disableBanNodes,
    radiusCacheSize: radiusCacheSize,
  )

func fromLogRadius*(T: type UInt256, logRadius: uint16): T =
  # Get the max value of the logRadius range
  pow((2).stuint(256), logRadius) - 1

func getProtocolId*(subnetwork: PortalSubnetwork): PortalProtocolId =
  ## Return the network's protocol ID for the given subnetwork
  const portalPrefix = byte(0x50)

  case subnetwork
  of PortalSubnetwork.history:
    [portalPrefix, 0x00]
  of PortalSubnetwork.beacon:
    [portalPrefix, 0x0C]

func `$`*(id: PortalProtocolId): string =
  id.toHex()

func getPortalEnrField*(network: PortalNetwork): PortalEnrField =
  ## Return the node's Portal ENR field based on the network
  case network
  of PortalNetwork.none:
    PortalEnrField.init(localSupportedVersionMin, localSupportedVersionMax, 0.chainId())
  of PortalNetwork.mainnet:
    PortalEnrField.init(localSupportedVersionMin, localSupportedVersionMax, 1.chainId())

## Confutils parsers

proc parseCmdArg*(T: type RadiusConfig, p: string): T {.raises: [ValueError].} =
  if p.startsWith("dynamic") and len(p) == 7:
    RadiusConfig(kind: Dynamic)
  elif p.startsWith("static:"):
    let num = p[7 ..^ 1]
    let parsed =
      try:
        uint16.parseCmdArg(num)
      except ValueError:
        let msg = "Provided logRadius: " & num & " is not a valid number"
        raise newException(ValueError, msg)

    if parsed > 256:
      raise newException(ValueError, "Provided logRadius should be <= 256")

    RadiusConfig(kind: Static, logRadius: parsed)
  else:
    let parsed =
      try:
        uint16.parseCmdArg(p)
      except ValueError:
        let msg =
          "Not supported radius config option: " & p & " . " &
          "Supported options: dynamic and static:logRadius"
        raise newException(ValueError, msg)

    if parsed > 256:
      raise newException(ValueError, "Provided logRadius should be <= 256")

    RadiusConfig(kind: Static, logRadius: parsed)

proc completeCmdArg*(T: type RadiusConfig, val: string): seq[string] =
  return @[]

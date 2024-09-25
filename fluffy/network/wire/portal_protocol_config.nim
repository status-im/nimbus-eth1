# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/strutils, confutils, chronos, stint, eth/p2p/discoveryv5/routing_table

type
  PortalNetwork* = enum
    none
    mainnet
    angelfood

  # The Portal sub-protocols
  PortalSubnetwork* = enum
    state
    history
    beacon
    transactionIndex
    verkleState
    transactionGossip

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
    radiusConfig*: RadiusConfig
    disablePoke*: bool
    maxGossipNodes*: int

const
  defaultRadiusConfig* = RadiusConfig(kind: Dynamic)
  defaultRadiusConfigDesc* = $defaultRadiusConfig.kind
  defaultDisablePoke* = false
  defaultMaxGossipNodes = 4
  revalidationTimeout* = chronos.seconds(30)

  defaultPortalProtocolConfig* = PortalProtocolConfig(
    tableIpLimits: DefaultTableIpLimits,
    bitsPerHop: DefaultBitsPerHop,
    radiusConfig: defaultRadiusConfig,
    disablePoke: defaultDisablePoke,
    maxGossipNodes: defaultMaxGossipNodes,
  )

proc init*(
    T: type PortalProtocolConfig,
    tableIpLimit: uint,
    bucketIpLimit: uint,
    bitsPerHop: int,
    radiusConfig: RadiusConfig,
    disablePoke: bool,
    maxGossipNodes: int,
): T =
  PortalProtocolConfig(
    tableIpLimits:
      TableIpLimits(tableIpLimit: tableIpLimit, bucketIpLimit: bucketIpLimit),
    bitsPerHop: bitsPerHop,
    radiusConfig: radiusConfig,
    disablePoke: disablePoke,
    maxGossipNodes: maxGossipNodes,
  )

func fromLogRadius*(T: type UInt256, logRadius: uint16): T =
  # Get the max value of the logRadius range
  pow((2).stuint(256), logRadius) - 1

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

# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/strutils, confutils, chronos, stint, eth/p2p/discoveryv5/routing_table

type
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

const
  defaultRadiusConfig* = RadiusConfig(kind: Dynamic)
  defaultRadiusConfigDesc* = $defaultRadiusConfig.kind
  defaultDisablePoke* = false
  revalidationTimeout* = chronos.seconds(30)

  defaultPortalProtocolConfig* = PortalProtocolConfig(
    # TODO / IMPORTANT NOTE:
    # This must be set back to `DefaultTableIpLimits` as soon as there are
    # enough nodes in the Portal network that we don't need to rely on the
    # Fluffy fleet. Currently, during development, convenience is taken above
    # security, this must not remain.
    tableIpLimits: TableIpLimits(tableIpLimit: 32, bucketIpLimit: 16),
    bitsPerHop: DefaultBitsPerHop,
    radiusConfig: defaultRadiusConfig,
  )

proc init*(
    T: type PortalProtocolConfig,
    tableIpLimit: uint,
    bucketIpLimit: uint,
    bitsPerHop: int,
    radiusConfig: RadiusConfig,
    disablePoke: bool,
): T =
  PortalProtocolConfig(
    tableIpLimits:
      TableIpLimits(tableIpLimit: tableIpLimit, bucketIpLimit: bucketIpLimit),
    bitsPerHop: bitsPerHop,
    radiusConfig: radiusConfig,
    disablePoke: disablePoke,
  )

func fromLogRadius*(T: type UInt256, logRadius: uint16): T =
  # Get the max value of the logRadius range
  pow((2).stuint(256), logRadius) - 1

func getInitialRadius*(rc: RadiusConfig): UInt256 =
  case rc.kind
  of Static:
    return UInt256.fromLogRadius(rc.logRadius)
  of Dynamic:
    # In case of a dynamic radius we start from the maximum value to quickly
    # gather as much data as possible, and also make sure each data piece in
    # the database is in our range after a node restart.
    # Alternative would be to store node the radius in database, and initialize
    # it from database after a restart
    return UInt256.high()

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

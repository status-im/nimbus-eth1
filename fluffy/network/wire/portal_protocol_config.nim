import
  std/strutils,
  confutils,
  eth/p2p/discoveryv5/routing_table

type
  RadiusConfigKind* = enum
    Static, Dynamic

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

const
  defaultRadiusConfig* = RadiusConfig(kind: Dynamic)
  defaultRadiusConfigDesc* = $defaultRadiusConfig.kind

  defaultPortalProtocolConfig* = PortalProtocolConfig(
    tableIpLimits: DefaultTableIpLimits,
    bitsPerHop: DefaultBitsPerHop,
    radiusConfig: defaultRadiusConfig
  )

proc init*(
    T: type PortalProtocolConfig,
    tableIpLimit: uint,
    bucketIpLimit: uint,
    bitsPerHop: int,
    radiusConfig: RadiusConfig): T =

  PortalProtocolConfig(
    tableIpLimits: TableIpLimits(
      tableIpLimit: tableIpLimit,
      bucketIpLimit: bucketIpLimit),
    bitsPerHop: bitsPerHop,
    radiusConfig: radiusConfig
  )

proc parseCmdArg*(T: type RadiusConfig, p: TaintedString): T
    {.raises: [Defect, ConfigurationError].} =
  if p.startsWith("dynamic") and len(p) == 7:
    RadiusConfig(kind: Dynamic)
  elif p.startsWith("static:"):
    let num = p[7..^1]
    let parsed =
      try:
        uint16.parseCmdArg(num)
      except ValueError:
        let msg = "Provided logRadius: " & num & " is not a valid number"
        raise newException(ConfigurationError, msg)

    if parsed > 256:
      raise newException(
        ConfigurationError, "Provided logRadius should be <= 256"
      )

    RadiusConfig(kind: Static, logRadius: parsed)
  else:
    let parsed =
      try:
        uint16.parseCmdArg(p)
      except ValueError:
        let msg =
          "Not supported radius config option: " & p & " . " &
          "Supported options: dynamic and static:logRadius"
        raise newException(ConfigurationError, msg)

    if parsed > 256:
      raise newException(
        ConfigurationError, "Provided logRadius should be <= 256")

    RadiusConfig(kind: Static, logRadius: parsed)

proc completeCmdArg*(T: type RadiusConfig, val: TaintedString): seq[string] =
  return @[]

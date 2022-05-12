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
    return RadiusConfig(kind: Dynamic)
  elif p.startsWith("static:"):
    let num = p[7..^1]
    try:
      let parsed = uint16.parseCmdArg(num)

      if parsed > 256:
        raise newException(
          ConfigurationError, "Provided logRadius should be <= 256"
        )

      return RadiusConfig(kind: Static, logRadius: parsed)
    except ValueError:
      let msg = "Provided logRadius: " & num & " is not a valid number"
      raise newException(
        ConfigurationError, msg
      )
  else:
    let msg = 
      "Not supported radius config option: " & p & " . " & 
      "Supported options: dynamic, static:logRadius"
    raise newException(
      ConfigurationError, 
      msg
    )

proc completeCmdArg*(T: type RadiusConfig, val: TaintedString): seq[string] =
  return @[]

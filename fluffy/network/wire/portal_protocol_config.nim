import
  eth/p2p/discoveryv5/routing_table

type
  PortalProtocolConfig* = object
    tableIpLimits*: TableIpLimits
    bitsPerHop*: int

const
  defaultPortalProtocolConfig* = PortalProtocolConfig(
    tableIpLimits: DefaultTableIpLimits,
    bitsPerHop: DefaultBitsPerHop)

proc init*(
    T: type PortalProtocolConfig,
    tableIpLimit: uint,
    bucketIpLimit: uint,
    bitsPerHop: int): T =

  PortalProtocolConfig(
    tableIpLimits: TableIpLimits(
      tableIpLimit: tableIpLimit,
      bucketIpLimit: bucketIpLimit),
    bitsPerHop: bitsPerHop
  )


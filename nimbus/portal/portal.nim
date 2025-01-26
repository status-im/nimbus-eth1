# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Creates the direct integration interface for fluffy - our portal client

import
  chronicles,
  results,
  ./portal_rpc,
  ../config,
  ../utils/era_helpers,
  eth/common/keys, # rng
  eth/net/nat, # setupAddress
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  eth/p2p/discoveryv5/enr,
  ../../fluffy/portal_node,
  ../../fluffy/common/common_utils,
  ../../fluffy/network_metadata,
  ../../fluffy/version

logScope:
  topic = "portal"

type
  PortalClientRef* = ref object
    fluffy: ref PortalNode
    rpc: PortalRpc
    limit*: uint64 # blockNumber limit till portal is activated, EIP specific

proc isPortalEnabled*(conf: NimbusConf): bool =
  conf.portalUrl.len > 0

proc init*(T: type PortalClientRef, conf: NimbusConf): T =
  let rpc = conf.getPortalRpc().valueOr:
    return T(
      fluffy: nil, # Add fluffy support
      limit: 0
    )
  
  T(
    fluffy: nil,
    rpc: rpc,
    limit: 0
  )

proc getBlock*(pc: PortalClientRef, blockNumber: uint64): Result[BlockObject, string] =
  debug "Fetching block from portal"
  try:
    return ok(pc.rpc.getBlockFromRpc(blockNumber))
  except CatchableError as e:
    debug "Failed to fetch block from portal", err=e.msg
    return err(e.msg)
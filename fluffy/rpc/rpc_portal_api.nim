# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/sequtils,
  json_rpc/[rpcproxy, rpcserver],
  ../network/wire/portal_protocol,
  ./rpc_types

export rpcserver

# Note:
# Using a string for the network parameter will give an error in the rpc macro:
# Error: Invalid node kind nnkInfix for macros.`$`
# Using a static string works but some sandwich problem seems to be happening,
# as the proc becomes generic, where the rpc macro from router.nim can no longer
# be found, which is why we export rpcserver which should export router.
proc installPortalApiHandlers*(
    rpcServer: RpcServer|RpcProxy, p: PortalProtocol, network: static string)
    {.raises: [Defect, CatchableError].} =
  ## Portal routing table and portal wire json-rpc API is not yet defined but
  ## will look something similar as what exists here now:
  ## https://github.com/ethereum/portal-network-specs/pull/88

  rpcServer.rpc("portal_" & network & "_nodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServer.rpc("portal_" & network & "_routingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

  rpcServer.rpc("portal_" & network & "_recursiveFindNodes") do() -> seq[Record]:
    let discovered = await p.queryRandom()
    return discovered.map(proc(n: Node): Record = n.record)

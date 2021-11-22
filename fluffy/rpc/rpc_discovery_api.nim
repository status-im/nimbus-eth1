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
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ./rpc_types

proc installDiscoveryApiHandlers*(rpcServerWithProxy: var RpcProxy,
    d: discv5_protocol.Protocol) {.raises: [Defect, CatchableError].} =
  ## Discovery v5 JSON-RPC API such as defined here:
  ## https://ddht.readthedocs.io/en/latest/jsonrpc.html
  ## and here:
  ## https://github.com/ethereum/portal-network-specs/pull/88
  ## Note: There are quite some descrepencies between the two, can only
  ## implement exactly once specification is settled.

  rpcServerWithProxy.rpc("discv5_nodeInfo") do() -> NodeInfo:
    return d.routingTable.getNodeInfo()

  rpcServerWithProxy.rpc("discv5_routingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(d.routingTable)

  rpcServerWithProxy.rpc("discv5_recursiveFindNodes") do() -> seq[string]:
    # TODO: Not according to the specification currently. Should do a lookup
    # here instead of query, and the node_id is a parameter to be passed.
    let discovered = await d.queryRandom()
    return discovered.map(proc(n: Node): string = n.record.toURI())

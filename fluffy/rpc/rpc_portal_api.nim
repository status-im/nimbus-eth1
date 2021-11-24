# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/[rpcproxy, rpcserver],
  ../network/wire/portal_protocol,
  ./rpc_types

# TODO:
# Trying to make this dynamic by passing in a network sub string results in:
# Error: Invalid node kind nnkInfix for macros.`$`
proc installPortalStateApiHandlers*(rpcServerWithProxy: var RpcProxy, p: PortalProtocol)
    {.raises: [Defect, CatchableError].} =
  ## Portal routing table and portal wire json-rpc API is not yet defined but
  ## will look something similar as what exists here now:
  ## https://github.com/ethereum/portal-network-specs/pull/88

  rpcServerWithProxy.rpc("portal_state_nodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServerWithProxy.rpc("portal_state_routingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

proc installPortalHistoryApiHandlers*(rpcServerWithProxy: var RpcProxy, p: PortalProtocol)
    {.raises: [Defect, CatchableError].} =

  rpcServerWithProxy.rpc("portal_history_nodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServerWithProxy.rpc("portal_history_routingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

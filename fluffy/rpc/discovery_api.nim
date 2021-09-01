# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/[rpcproxy, rpcserver], stint,
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/enr

type 
  NodeInfoResponse = object
    node_id: string
    enr: string

proc installDiscoveryApiHandlers*(rpcServerWithProxy: var RpcProxy, discovery: discv5_protocol.Protocol)
  {.raises: [Defect, CatchableError].} =

    # https://ddht.readthedocs.io/en/latest/jsonrpc.html#discv5-nodeinfo
    rpcServerWithProxy.rpc("discv5_nodeInfo") do() -> NodeInfoResponse:
      let localNodeId = "0x" & discovery.localNode.id.toHex()
      let localNodeEnr = discovery.localNode.record.toURI()
      return NodeInfoResponse(node_id: localNodeId, enr: localNodeEnr)


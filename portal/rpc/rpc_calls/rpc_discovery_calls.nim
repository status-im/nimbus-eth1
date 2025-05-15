# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import json_rpc/rpcclient, ../rpc_types, ../rpc_discovery_api

export rpc_types, rpc_discovery_api

createRpcSigsFromNim(RpcClient):
  # Discovery v5 json-rpc calls
  proc discv5_nodeInfo(): NodeInfo
  proc discv5_updateNodeInfo(kvPairs: seq[(string, string)]): RoutingTableInfo
  proc discv5_routingTableInfo(): RoutingTableInfo

  proc discv5_addEnr(enr: Record): bool
  proc discv5_addEnrs(enrs: seq[Record]): bool
  proc discv5_getEnr(nodeId: NodeId): Record
  proc discv5_deleteEnr(nodeId: NodeId): bool
  proc discv5_lookupEnr(nodeId: NodeId): Record

  proc discv5_ping(nodeId: Record): PongResponse
  proc discv5_findNode(nodeId: Record, distances: seq[uint16]): seq[Record]
  proc discv5_talkReq(nodeId: Record, protocol, payload: string): string

  proc discv5_recursiveFindNodes(nodeId: NodeId): seq[Record]

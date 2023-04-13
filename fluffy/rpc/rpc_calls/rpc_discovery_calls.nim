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

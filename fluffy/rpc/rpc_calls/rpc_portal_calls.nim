## Portal State Network json-rpc calls
proc portal_state_nodeInfo(): NodeInfo
proc portal_state_routingTableInfo(): RoutingTableInfo
proc portal_state_lookupEnr(nodeId: NodeId): Record
proc portal_state_addEnrs(enrs: seq[Record]): bool
proc portal_state_ping(enr: Record): tuple[
  seqNum: uint64, customPayload: string]
proc portal_state_findNodes(enr: Record): seq[Record]
proc portal_state_findContent(enr: Record, contentKey: string): tuple[
  connectionId: Option[string],
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_state_findContentExt(enr: Record, contentKey: string): tuple[
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_state_offerExt(enr: Record, contentKey: string): bool
proc portal_state_recursiveFindNodes(): seq[Record]

## Portal History Network json-rpc calls
proc portal_history_nodeInfo(): NodeInfo
proc portal_history_routingTableInfo(): RoutingTableInfo
proc portal_history_lookupEnr(nodeId: NodeId): Record
proc portal_history_addEnrs(enrs: seq[Record]): bool
proc portal_history_ping(enr: Record): tuple[
  seqNum: uint64, customPayload: string]
proc portal_history_findNodes(enr: Record): seq[Record]
proc portal_history_findContent(enr: Record, contentKey: string): tuple[
  connectionId: Option[string],
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_history_findContentExt(enr: Record, contentKey: string): tuple[
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_history_offerExt(enr: Record, contentKey: string): bool
proc portal_history_recursiveFindNodes(): seq[Record]

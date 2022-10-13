## Portal State Network json-rpc calls
proc portal_stateNodeInfo(): NodeInfo
proc portal_stateRoutingTableInfo(): RoutingTableInfo
proc portal_stateLookupEnr(nodeId: NodeId): Record
proc portal_stateAddEnrs(enrs: seq[Record]): bool
proc portal_statePing(enr: Record): tuple[
  seqNum: uint64, customPayload: string]
proc portal_stateFindNodes(enr: Record): seq[Record]
proc portal_stateFindContentRaw(enr: Record, contentKey: string): tuple[
  connectionId: Option[string],
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_stateFindContent(enr: Record, contentKey: string): tuple[
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_stateOffer(enr: Record, contentKey: string): bool
proc portal_stateRecursiveFindNodes(): seq[Record]

## Portal History Network json-rpc calls
proc portal_historyNodeInfo(): NodeInfo
proc portal_historyRoutingTableInfo(): RoutingTableInfo
proc portal_historyLookupEnr(nodeId: NodeId): Record
proc portal_historyAddEnrs(enrs: seq[Record]): bool
proc portal_historyPing(enr: Record): tuple[
  seqNum: uint64, customPayload: string]
proc portal_historyFindNodes(enr: Record): seq[Record]
proc portal_historyFindContentRaw(enr: Record, contentKey: string): tuple[
  connectionId: Option[string],
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_historyFindContent(enr: Record, contentKey: string): tuple[
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_historyOffer(contentKey: string, content: string): int
proc portal_historyRecursiveFindNodes(): seq[Record]

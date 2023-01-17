## Portal State Network json-rpc calls
proc portal_stateNodeInfo(): NodeInfo
proc portal_stateRoutingTableInfo(): RoutingTableInfo
proc portal_stateAddEnr(enr: Record): bool
proc portal_stateAddEnrs(enrs: seq[Record]): bool
proc portal_stateGetEnr(nodeId: NodeId): Record
proc portal_stateDeleteEnr(nodeId: NodeId): bool
proc portal_stateLookupEnr(nodeId: NodeId): Record
proc portal_statePing(enr: Record): tuple[
  enrSeq: uint64, customPayload: string]
proc portal_stateFindNodes(enr: Record): seq[Record]
proc portal_stateFindContent(enr: Record, contentKey: string): tuple[
  connectionId: Option[string],
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_stateFindContentFull(enr: Record, contentKey: string): tuple[
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_stateOffer(
  enr: Record, contentKey: string, contentValue: string): string
proc portal_stateRecursiveFindNodes(nodeId: NodeId): seq[Record]
proc portal_stateRecursiveFindContent(contentKey: string): string
proc portal_stateStore(contentKey: string, contentValue: string): bool
proc portal_stateLocalContent(contentKey: string): string
proc portal_stateGossip(contentKey: string, contentValue: string): int

## Portal History Network json-rpc calls
proc portal_historyNodeInfo(): NodeInfo
proc portal_historyRoutingTableInfo(): RoutingTableInfo
proc portal_historyAddEnr(enr: Record): bool
proc portal_historyAddEnrs(enrs: seq[Record]): bool
proc portal_historyGetEnr(nodeId: NodeId): Record
proc portal_historyDeleteEnr(nodeId: NodeId): bool
proc portal_historyLookupEnr(nodeId: NodeId): Record
proc portal_historyPing(enr: Record): tuple[
  enrSeq: uint64, customPayload: string]
proc portal_historyFindNodes(enr: Record): seq[Record]
proc portal_historyFindContent(enr: Record, contentKey: string): tuple[
  connectionId: Option[string],
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_historyFindContentFull(enr: Record, contentKey: string): tuple[
  content: Option[string],
  enrs: Option[seq[Record]]]
proc portal_historyOffer(
  enr: Record, contentKey: string, contentValue: string): string
proc portal_historyRecursiveFindNodes(nodeId: NodeId): seq[Record]
proc portal_historyRecursiveFindContent(contentKey: string): string
proc portal_historyStore(contentKey: string, contentValue: string): bool
proc portal_historyLocalContent(contentKey: string): string
proc portal_historyGossip(contentKey: string, contentValue: string): int

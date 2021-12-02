## Portal State Network json-rpc calls
proc portal_state_nodeInfo(): NodeInfo
proc portal_state_routingTableInfo(): RoutingTableInfo
proc portal_state_recursiveFindNodes(): seq[Record]

## Portal History Network json-rpc calls
proc portal_history_nodeInfo(): NodeInfo
proc portal_history_routingTableInfo(): RoutingTableInfo
proc portal_history_recursiveFindNodes(): seq[Record]

## Portal History Network json-rpc debug & testing calls
proc portal_history_store(contentKey: string, content: string): bool
proc portal_history_storeContent(dataFile: string): bool
proc portal_history_propagate(dataFile: string): bool
proc portal_history_propagateHeaders(dataFile: string): bool
proc portal_history_propagateBlock(dataFile: string, blockHash: string): bool
proc portal_history_propagateEpochAccumulator(dataFile: string): bool
proc portal_history_propagateEpochAccumulators(path: string): bool
proc portal_history_storeContentInNodeRange(
    dbPath: string, max: uint32, starting: uint32): bool
proc portal_history_offerContentInNodeRange(
    dbPath: string, nodeId: NodeId, max: uint32, starting: uint32): int
proc portal_history_depthContentPropagate(
    dbPath: string, max: uint32): bool
proc portal_history_breadthContentPropagate(
    dbPath: string): bool

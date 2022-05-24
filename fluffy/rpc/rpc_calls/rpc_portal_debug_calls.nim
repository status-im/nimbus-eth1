## Portal History Network json-rpc debug & testing calls
proc portal_history_store(contentKey: string, content: string): bool
proc portal_history_storeContent(dataFile: string): bool
proc portal_history_propagate(dataFile: string): bool
proc portal_history_propagateBlock(dataFile: string, blockHash: string): bool

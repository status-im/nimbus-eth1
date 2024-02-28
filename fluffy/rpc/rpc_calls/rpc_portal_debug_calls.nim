# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Portal History Network json-rpc debug & testing calls
proc portal_history_storeContent(dataFile: string): bool
proc portal_history_propagate(dataFile: string): bool
proc portal_history_propagateHeaders(dataFile: string): bool
proc portal_history_propagateBlock(dataFile: string, blockHash: string): bool
proc portal_history_propagateEpochAccumulator(dataFile: string): bool
proc portal_history_propagateEpochAccumulators(path: string): bool
proc portal_history_storeContentInNodeRange(
  dbPath: string, max: uint32, starting: uint32
): bool

proc portal_history_offerContentInNodeRange(
  dbPath: string, nodeId: NodeId, max: uint32, starting: uint32
): int

proc portal_history_depthContentPropagate(dbPath: string, max: uint32): bool
proc portal_history_breadthContentPropagate(dbPath: string): bool

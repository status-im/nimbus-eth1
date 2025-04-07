# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[deques, tables],
  ./chain_branch,
  ../../../common,
  ../../../db/core_db

export deques, tables

type
  ForkedChainRef* = ref object
    com*: CommonRef
    hashToBlock* : Table[Hash32, BlockPos]
      # A map of block hash to a block position in a branch.

    branches*    : seq[BranchRef]
    baseBranch*  : BranchRef
      # A branch contain the base block

    activeBranch*: BranchRef
      # Every time a new block added to a branch,
      # that branch automatically become the active branch.

    txRecords    : Table[Hash32, (Hash32, uint64)]
      # A map of transsaction hashes to block hash and block number.

    baseTxFrame* : CoreDbTxRef
      # Frame that skips all in-memory state that ForkedChain holds - used to
      # lookup items straight from the database

    baseDistance*: uint64
      # Minimum number of blocks and its state stored in memory.
      # User can query for block state while it is still in memory.
      # Any state older than base block are purged.

    lastSnapshots*: array[10, CoreDbTxRef]
    lastSnapshotPos*: int
      # The snapshot contains the cumulative changes of all ancestors and
      # txFrame allowing the lookup recursion to stop whenever it is encountered.

    pendingFCU*  : Hash32
      # When we know finalizedHash from CL but has yet to resolve
      # the hash into a latestFinalizedBlockNumber

    latestFinalizedBlockNumber*: uint64
      # When our latest imported block is far away from
      # latestFinalizedBlockNumber, we can move the base
      # forward when importing block

    persistBatchSize*: uint64
      # When move forward, this is the minimum distance
      # to move the base. And the bulk writing can works
      # efficiently.

# ----------------

func txRecords*(c: ForkedChainRef): var Table[Hash32, (Hash32, uint64)] =
  ## Avoid clash with `forked_chain.txRecords()`
  c.txRecords

func notifyBlockHashAndNumber*(c: ForkedChainRef,
                               blockHash: Hash32,
                               blockNumber: uint64) =
  ## Syncer will tell FC a block have been downloaded,
  ## please check if it's useful for you.
  if blockHash == c.pendingFCU:
    c.latestFinalizedBlockNumber = blockNumber

# End

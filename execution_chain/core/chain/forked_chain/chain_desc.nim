# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[tables, deques],
  chronos,
  ../../../common,
  ../../../db/[core_db, fcu_db],
  ../../../portal/portal,
  ./block_quarantine,
  ./chain_branch

export tables

type
  QueueItem* = object
    responseFut*: Future[Result[void, string]].Raising([CancelledError])
    handler*: proc(): Future[Result[void, string]] {.async: (raises: [CancelledError]).}

  ForkedChainRef* = ref object
    com*: CommonRef
    hashToBlock* : Table[Hash32, BlockRef]
      # A map of block hash to a block.

    base*        : BlockRef
      # The base block, the last block stored in database.
      # Any blocks newer than base is kept in memory.

    baseQueue*   : Deque[BlockRef]
      # Queue of blocks that will become base.
      # This queue will be filled by `importBlock` or `forkChoice`.
      # Then consumed by the `processQueue` async worker.

    lastBaseLogTime*: EthTime

    persistedCount*: uint
      # Count how many blocks persisted when `baseQueue`
      # consumed.

    latest*      : BlockRef
      # Every time a new block added,
      # that block automatically become the latest block.

    heads*       : seq[BlockRef]
      # Candidate heads of candidate chains

    quarantine*  : Quarantine

    txRecords    : Table[Hash32, (Hash32, uint64)]
      # A map of transsaction hashes to block hash and block number.

    baseTxFrame* : CoreDbTxRef
      # Frame that skips all in-memory state that ForkedChain holds - used to
      # lookup items straight from the database

    baseDistance*: uint64
      # Minimum number of blocks and its state stored in memory.
      # User can query for block state while it is still in memory.
      # Any state older than base block are purged.

    eagerStateRoot*: bool

    pendingFCU*  : Hash32
      # When we know finalizedHash from CL but has yet to resolve
      # the hash into a `latestFinalized` hash/number pair

    latestFinalized*: FcuHashAndNumber
      # When our latest imported block is far away from
      # latestFinalizedBlockNumber, we can move the base
      # forward when importing block

    persistBatchSize*: uint64
      # When move forward, this is the minimum distance
      # to move the base. And the bulk writing can works
      # efficiently.

    dynamicBatchSize*: bool
      # Enable adjusting the persistBatchSize dynamically based on the
      # time it takes to update base.

    maxBlobs*: Option[uint8]
      # For EIP-7872; allows constraining of max blobs packed into each payload

    portal*: HistoryExpiryRef
      # History Expiry tracker and portal access entry point

    fcuHead*: FcuHashAndNumber
    fcuSafe*: FcuHashAndNumber
      # Tracking current head and safe block of FC serialization.

    queue*: AsyncQueue[QueueItem]
    processingQueueLoop*: Future[void].Raising([CancelledError])
      # Prevent async re-entrancy messing up FC state
      # on both `importBlock` and `forkChoice`.

# ------------------------------------------------------------------------------
# These functions are private to ForkedChainRef
# ------------------------------------------------------------------------------

func txRecords*(c: ForkedChainRef): var Table[Hash32, (Hash32, uint64)] =
  ## Avoid clash with `forked_chain.txRecords()`
  c.txRecords

func tryUpdatePendingFCU*(c: ForkedChainRef, finHash: Hash32, number: uint64): bool =
  c.pendingFCU = zeroHash32
  if number > c.latestFinalized.number:
    c.latestFinalized = FcuHashAndNumber(number: number, hash: finHash)
    return true
  # false

# End

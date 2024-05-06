# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Move Head of Block Chain
## ==================================================
##


import
  std/[tables],
  ../../../common/common,
  ../tx_chain,
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  chronicles,
  eth/keys,
  stew/keyed_queue

{.push raises: [].}

type
  TxHeadDiffRef* = ref object ##\
    ## Diff data, txs changes that apply after changing the head\
    ## insertion point of the block chain

    addTxs*: KeyedQueue[Hash256, PooledTransaction] ##\
      ## txs to add; using a queue makes it more intuive to delete
      ## items while travesing the queue in a loop.

    remTxs*: Table[Hash256,bool] ##\
      ## txs to remove

logScope:
  topics = "tx-pool head adjust"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# use it as a stack/lifo as the ordering is reversed
proc insert(xp: TxPoolRef; kq: TxHeadDiffRef; blockHash: Hash256)
    {.gcsafe,raises: [CatchableError].} =
  let db = xp.chain.com.db
  for tx in db.getBlockBody(blockHash).transactions:
    if tx.versionedHashes.len > 0:
      # EIP-4844 blobs are not persisted and cannot be re-broadcasted.
      # Note that it is also not possible to crete a cache in all cases,
      # as we may have never seen the actual blob sidecar while syncing.
      # Only the consensus layer persists the blob sidecar.
      continue
    kq.addTxs[tx.itemID] = PooledTransaction(tx: tx)

proc remove(xp: TxPoolRef; kq: TxHeadDiffRef; blockHash: Hash256)
    {.gcsafe,raises: [CatchableError].} =
  let db = xp.chain.com.db
  for tx in db.getBlockBody(blockHash).transactions:
    kq.remTxs[tx.itemID] = true

proc new(T: type TxHeadDiffRef): T =
  new result

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(218): func (pool *TxPool) reset(oldHead, newHead ...
proc headDiff*(xp: TxPoolRef;
               newHead: BlockHeader): Result[TxHeadDiffRef,TxInfo]
    {.gcsafe,raises: [CatchableError].} =
  ## This function caclulates the txs differences between the cached block
  ## chain head to a new head implied by the argument `newHeader`. Differences
  ## are returned as two tables for adding and removing txs. The tables table
  ## for adding transactions (is a queue and) preserves the order of the txs
  ## from the block chain.
  ##
  ## Now, considering add/delete tx actions needed when replacing the cached
  ## *current head* position by the *new head* position (as derived from the
  ## function argument `newHeader`), the most complex case of a block chain
  ## might look as follows:
  ## ::
  ##  .                      o---o-- .. ---o---o
  ##  .                     /                  ^
  ##  .  block chain .. ---o---o---o .. --o    |
  ##  .                    ^              ^    |
  ##  .                    |              |    |
  ##  .       common ancestor             |    |
  ##  .                                   |    |
  ##  .                             new head   |
  ##  .                                        |
  ##  .                              current head
  ##
  ## Legend
  ## * the bullet *o* stands for a block
  ## * a link *---* between two blocks indicates that the block number to
  ##   the right increases by *1*
  ## * the *common ancestor* is chosen with the largest possible block number
  ##   not exceeding the block numbers of both, the *current head* and the
  ##   *new head*
  ## * the branches to the right of the *common ancestor* may collapse to a
  ##   a single branch (in which case at least one of *old head* or
  ##   *new head* collapses with the *common ancestor*)
  ## * there is no assumption on the block numbers of *new head* and
  ##   *current head* as of which one is greater, they might also be equal
  ##
  ## Consider the two sets *ADD* and *DEL* where
  ##
  ## *ADD*
  ##   is the set of txs on the branch between the *common ancestor* and
  ##   the *current head*, and
  ## *DEL*
  ##   is the set of txs on the branch between the *common ancestor* and
  ##   the *new head*
  ##
  ## Then, the set of txs to be added to the pool is *ADD - DEL* and the set
  ## of txs to be removed is *DEL - ADD*.
  ##
  let
    curHead = xp.chain.head
    curHash = curHead.blockHash
    newHash = newHead.blockHash
    db      = xp.chain.com.db

  var ignHeader: BlockHeader
  if not db.getBlockHeader(newHash, ignHeader):
    # sanity check
    warn "Tx-pool head forward for non-existing header",
      newHead = newHash,
      newNumber = newHead.blockNumber
    return err(txInfoErrForwardHeadMissing)

  if not db.getBlockHeader(curHash, ignHeader):
    # This can happen if a `setHead()` is performed, where we have discarded
    # the old head from the chain.
    if curHead.blockNumber <= newHead.blockNumber:
      warn "Tx-pool head forward from detached current header",
        curHead = curHash,
        curNumber = curHead.blockNumber
      return err(txInfoErrAncestorMissing)
    debug "Tx-pool reset with detached current head",
      curHeader = curHash,
      curNumber = curHead.blockNumber,
      newHeader = newHash,
      newNumber = newHead.blockNumber
    return err(txInfoErrChainHeadMissing)

  # Equalise block numbers between branches (typically, these btanches
  # collapse and there is a single strain only)
  var
    txDiffs = TxHeadDiffRef.new

    curBranchHead = curHead
    curBranchHash = curHash
    newBranchHead = newHead
    newBranchHash = newHash

  if newHead.blockNumber < curHead.blockNumber:
    #
    # new head block number smaller than the current head one
    #
    #              ,o---o-- ..--o
    #             /             ^
    #            /              |
    #       ----o---o---o       |
    #                   ^       |
    #                   |       |
    #                  new  << current (step back this one)
    #
    # + preserve transactions on the upper branch blocks,
    #
    # + txs of blocks with numbers between #new..#current need to be
    #   re-inserted into the pool
    #
    while newHead.blockNumber < curBranchHead.blockNumber:
      xp.insert(txDiffs, curBranchHash)
      let
        tmpHead = curBranchHead # cache value for error logging
        tmpHash = curBranchHash
      curBranchHash = curBranchHead.parentHash # decrement block number
      if not db.getBlockHeader(curBranchHash, curBranchHead):
        error "Unrooted old chain seen by tx-pool",
          curBranchHead = tmpHash,
          curBranchNumber = tmpHead.blockNumber
        return err(txInfoErrUnrootedCurChain)
  else:
    #
    # current head block number smaller (or equal) than the new head one
    #
    #              ,o---o-- ..--o
    #             /             ^
    #            /              |
    #       ----o---o---o       |
    #                   ^       |
    #                   |       |
    #              current  << new (step back this one)
    #
    # + preserve some transactions on the upper branch blocks,
    #
    # + txs of blocks with numbers between #current..#new need to be
    #   deleted from the pool (as they are on the block chain, now)
    #
    while curHead.blockNumber < newBranchHead.blockNumber:
      xp.remove(txDiffs, newBranchHash)
      let
        tmpHead = newBranchHead # cache value for error logging
        tmpHash = newBranchHash
      newBranchHash = newBranchHead.parentHash # decrement block number
      if not db.getBlockHeader(newBranchHash, newBranchHead):
        error "Unrooted new chain seen by tx-pool",
          newBranchHead = tmpHash,
          newBranchNumber = tmpHead.blockNumber
        return err(txInfoErrUnrootedNewChain)

  # simultaneously step back until junction-head (aka common ancestor) while
  # preserving txs between block numbers #ancestor..#current unless
  # between #ancestor..#new
  while curBranchHash != newBranchHash:
    block:
      xp.insert(txDiffs, curBranchHash)
      let
        tmpHead = curBranchHead # cache value for error logging
        tmpHash = curBranchHash
      curBranchHash = curBranchHead.parentHash
      if not db.getBlockHeader(curBranchHash, curBranchHead):
        error "Unrooted old chain seen by tx-pool",
          curBranchHead = tmpHash,
          curBranchNumber = tmpHead.blockNumber
        return err(txInfoErrUnrootedCurChain)
    block:
      xp.remove(txDiffs, newBranchHash)
      let
        tmpHead = newBranchHead # cache value for error logging
        tmpHash = newBranchHash
      newBranchHash = newBranchHead.parentHash
      if not db.getBlockHeader(newBranchHash, newBranchHead):
        error "Unrooted new chain seen by tx-pool",
          newBranchHead = tmpHash,
          newBranchNumber = tmpHead.blockNumber
        return err(txInfoErrUnrootedNewChain)

  # figure out difference sets
  for itemID in txDiffs.addTxs.nextKeys:
    if txDiffs.remTxs.hasKey(itemID):
      txDiffs.addTxs.del(itemID) # ok to delete the current one on a KeyedQueue
      txDiffs.remTxs.del(itemID)

  ok(txDiffs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

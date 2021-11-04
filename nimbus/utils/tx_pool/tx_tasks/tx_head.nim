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
  ../../../db/db_chain,
  ../tx_dbhead,
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  chronicles,
  eth/[common, keys],
  stew/keyed_queue

type
  TxHeadDiffRef* = ref object ##\
    ## Diff data, txs changes that apply after changing the head\
    ## insertion point of the block chain
    addTxs*: KeyedQueue[Hash256,Transaction] ## txs to add, preserve order
    remTxs*: KeyedQueueNV[Hash256]           ## txs to remove

logScope:
  topics = "tx-pool head adjust"

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# use it as a stack/lifo as the ordering is reversed
proc insert(xp: TxPoolRef; kq: TxHeadDiffRef; blockHash: Hash256)
    {.gcsafe,raises: [Defect,CatchableError].} =
  for tx in xp.dbhead.db.getBlockBody(blockHash).transactions:
    discard kq.addTxs.prepend(tx.itemID,tx)

proc remove(xp: TxPoolRef; kq: TxHeadDiffRef; blockHash: Hash256)
    {.gcsafe,raises: [Defect,CatchableError].} =
  for tx in xp.dbhead.db.getBlockBody(blockHash).transactions:
    discard kq.addTxs.prepend(tx.itemID,tx)

proc init(T: type TxHeadDiffRef): T =
  new result

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(218): func (pool *TxPool) reset(oldHead, newHead ...
proc headDiff*(xp: TxPoolRef;
               newHeader: BlockHeader): Result[TxHeadDiffRef,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
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
    curHeader = xp.dbhead.header
    curHash = curHeader.blockHash
    newHash = newHeader.blockHash

  var ignHeader: BlockHeader
  if not xp.dbhead.db.getBlockHeader(newHash, ignHeader):
    # sanity check
    warn "Tx-pool head forward for non-existing header",
      newHeader = newHash,
      newNumber = newHeader.blockNumber
    return err(txInfoErrForwardHeadMissing)

  if not xp.dbhead.db.getBlockHeader(curHash, ignHeader):
    # This can happen if a `setHead()` is performed, where we have discarded
    # the old head from the chain.
    if curHeader.blockNumber <= newHeader.blockNumber:
      warn "Tx-pool head forward from detached current header",
        curHeader = curHash,
        curNumber = curHeader.blockNumber
      return err(txInfoErrAncestorMissing)
    debug "Tx-pool reset with detached current head",
      curHeader = curHash,
      curNumber = curHeader.blockNumber,
      newHeader = newHash,
      newNumber = newHeader.blockNumber
    return err(txInfoErrChainHeadMissing)

  # Equalise block numbers between branches (typically, these btanches
  # collapse and there is a single strain only)
  var
    txDiffs = TxHeadDiffRef.init

    curBranchHeader = curHeader
    curBranchHash = curHash
    newBranchHeader = newHeader
    newBranchHash = newHash

  if newHeader.blockNumber < curHeader.blockNumber:
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
    # preserve transactions on the upper branch block numbers
    # between #new..#current to be re-inserted into the pool
    #
    while newHeader.blockNumber < curBranchHeader.blockNumber:
      xp.insert(txDiffs, curBranchHash)
      let
        tmpHeader = curBranchHeader # cache value for error logging
        tmpHash = curBranchHash
      curBranchHash = curBranchHeader.parentHash # decrement block number
      if not xp.dbhead.db.getBlockHeader(curBranchHash, curBranchHeader):
        error "Unrooted old chain seen by tx-pool",
          curBranchHeader = tmpHash,
          curBranchNumber = tmpHeader.blockNumber
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
    # preserve transactions on the upper branch block numbers
    # between #current..#new to be deleted from the pool
    #
    while curHeader.blockNumber < newBranchHeader.blockNumber:
      xp.remove(txDiffs, curBranchHash)
      let
        tmpHeader = newBranchHeader # cache value for error logging
        tmpHash = newBranchHash
      newBranchHash = newBranchHeader.parentHash # decrement block number
      if not xp.dbhead.db.getBlockHeader(newBranchHash, newBranchHeader):
        error "Unrooted new chain seen by tx-pool",
          newBranchHeader = tmpHash,
          newBranchNumber = tmpHeader.blockNumber
        return err(txInfoErrUnrootedNewChain)

  # simultaneously step back until junction-head (aka common ancestor) while
  # preserving txs between block numbers #ancestor..#current unless
  # between #ancestor..#new
  while curBranchHash != newBranchHash:
    block:
      xp.insert(txDiffs, curBranchHash)
      let
        tmpHeader = curBranchHeader # cache value for error logging
        tmpHash = curBranchHash
      curBranchHash = curBranchHeader.parentHash
      if not xp.dbhead.db.getBlockHeader(curBranchHash, curBranchHeader):
        error "Unrooted old chain seen by tx-pool",
          curBranchHeader = tmpHash,
          curBranchNumber = tmpHeader.blockNumber
        return err(txInfoErrUnrootedCurChain)
    block:
      xp.remove(txDiffs, newBranchHash)
      let
        tmpHeader = newBranchHeader # cache value for error logging
        tmpHash = newBranchHash
      newBranchHash = newBranchHeader.parentHash
      if not xp.dbhead.db.getBlockHeader(newBranchHash, newBranchHeader):
        error "Unrooted new chain seen by tx-pool",
          newBranchHeader = tmpHash,
          newBranchNumber = tmpHeader.blockNumber
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

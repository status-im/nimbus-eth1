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
  ../../keyed_queue,
  ../tx_dbhead,
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  ./tx_add_tx,
  chronicles,
  eth/[common, keys]

type
  UpdateTxs = object
    addTxs: KeyedQueue[Hash256,Transaction] # txs to add
    remItems: KeyedQueueNV[TxItemRef]       # items for obsoleted txs

logScope:
  topics = "tx-pool adjust head"

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# use it as a stack/lifo as the ordering is reversed
proc collect(xp: TxPoolRef; kq: var UpdateTxs; blockHash: Hash256)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  for tx in xp.dbhead.db.getBlockBody(blockHash).transactions:
    # TODO: use items rether than txs => top nonce/sender
    discard kq.addTxs.prepend(tx.itemID,tx)

proc remove(xp: TxPoolRef; kq: var UpdateTxs; blockHash: Hash256)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  for tx in xp.dbhead.db.getBlockBody(blockHash).transactions:
    kq.addTxs.del(tx.itemID)
    let rc = xp.txDB.byItemID.eq(tx.itemID)
    if rc.isOK:
      discard kq.remItems.prepend(rc.value)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(218): func (pool *TxPool) reset(oldHead, newHead ...
proc adjustHead*(xp: TxPoolRef; newHeader: BlockHeader): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function moves the cached block chain head to a new head implied by
  ## the argument `newHeader`. For the most complex case, the current block
  ## chain might look as follows:
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
  ## * the bullet *o* stands for a block and a link *---* between two blocks
  ##   indicates that the block number to the right increases by *1*
  ## * the *common ancestor* is chosen with the largest possible block number
  ##   not exceeding the block numbers of both, the *current head* and the
  ##   *new head*
  ## * the branches to the right of the *common ancestor* may collapse to a
  ##   a single branch (in which case the *old* or the *new head* collapses
  ##   with the *common ancestor*)
  ## * there is no assumption on the block numbers of *new head* and
  ##   *current head* as which one is greater, they might also be equal
  ##
  ## Now, this function replaces the cached *current head* position by the
  ## *new head* position (as derived from the function argument `newHeader`.)
  ## Txs to the right of the *common ancestor* are re-inserted into the pool
  ## if unused (i.e. they belong to the set of txs on the *current head*
  ## branch unless they are on the *new head* branch already.)
  ##
  ## Note that after running this function, the packed block cache might
  ## not be up-to-date, anymore.
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

  # Using an ordered table witch complexity O(1) (which is not `OrderedTable`)
  # FIXME: ordering might not be needed but is nice for debugging
  var update: UpdateTxs

  # Equalise block numbers between branches (typically, these btanches
  # collapse and there is a single strain only)
  var
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
    #                  new  << current
    #
    # preserve transactions between new..current to be re-inserted into
    # the pool
    #
    while newHeader.blockNumber < curBranchHeader.blockNumber:
      xp.collect(update, curBranchHash)
      let
        tmpHeader = curBranchHeader # cache value for error logging
        tmpHash = curBranchHash
      curBranchHash = curBranchHeader.parentHash
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
    #              current  << new
    #
    # ignore transactions between current..new
    #
    while curHeader.blockNumber < newBranchHeader.blockNumber:
      let
        tmpHeader = newBranchHeader # cache value for error logging
        tmpHash = newBranchHash
      newBranchHash = newBranchHeader.parentHash
      if not xp.dbhead.db.getBlockHeader(newBranchHash, newBranchHeader):
        error "Unrooted new chain seen by tx-pool",
          newBranchHeader = tmpHash,
          newBranchNumber = tmpHeader.blockNumber
        return err(txInfoErrUnrootedNewChain)

  # simultaneously step back until junction-head (aka common ancestor) while
  # preserving txs between ancestor..current unless between ancestor..new
  while curBranchHash != newBranchHash:
    block:
      xp.collect(update, curBranchHash)
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
      xp.remove(update, newBranchHash)
      let
        tmpHeader = newBranchHeader # cache value for error logging
        tmpHash = newBranchHash
      newBranchHash = newBranchHeader.parentHash
      if not xp.dbhead.db.getBlockHeader(newBranchHash, newBranchHeader):
        error "Unrooted new chain seen by tx-pool",
          newBranchHeader = tmpHash,
          newBranchNumber = tmpHeader.blockNumber
        return err(txInfoErrUnrootedNewChain)

  # move block chain head
  xp.dbhead.update(newHeader)

  # re-inject transactions
  for kqp in update.addTxs.nextPairs:
    # Order makes sure that txs are added with correct nonce order. Note
    # that the database might end up with gaps between the sequence of newly
    # added and chain already on the system.
    var tx = kqp.data
    xp.addTx(tx)

  # delete already *mined* transactions
  for item in update.remItems.nextKeys:
    discard xp.txDB.dispose(item, reason = txInfoChainHeadUpdate)

  # TODO: verify the nonces

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

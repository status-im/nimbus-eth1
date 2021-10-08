# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool
## ================
##
## TODO:
## -----
## * Support `local` transactions (currently unsupported.) For now, all txs
##   are considered from `remote` accounts.
## * Redefining per account transactions with the same `nonce` is currently
##   unsupported. The old tx needs to be replaced by the new one while the old
##   one is moved to the waste basket.
##
##
## Transaction state diagram:
## --------------------------
## ::
##  .                   .                          .
##  .     <Job queue>   .   <Accounting system>    .   <Tip/waste disposal>
##  .                   .                          .
##  .                   .         +-----------+    .
##  .        +------------------> | queued(1) | -------------+
##  .        |          .         +-----------+    .         |
##  .        |          .            |   ^   ^     .         |
##  .        |          .            V   |   |     .         |
##  .        |          .    +------------+  |     .         |
##  .  --> enter(0) -------> | pending(2) |  |     .         |
##  .        |          .    +------------+  |     .         |
##  .        |          .     |     |        |     .         |
##  .        |          .     |     V        |     .         |
##  .        |          .     |   +-----------+    .         |
##  .        |          .     |   | staged(3) | -----------+ |
##  .        |          .     |   +-----------+    .       | |
##  .        |          .     |                    .       v v
##  .        |          .     |                    .   +----------------+
##  .        |          .     +----------------------> |  rejected(4)   |
##  .        +---------------------------------------> | (waste basket) |
##  .                   .                          .   +----------------+
##
##
## Job Queue
## ---------
##
## * Transactions enteringg the system (0):
##    + txs are added to the job queue an processed sequentially
##    + when processed, they are moved
##
## Accounting system
## -----------------
##
## * Queued transactions (1):
##   + queue txs after testing all right but not ready to fit into a block
##   + queued transactions are strored with meta-data and marked `txItemQueued`
##
## * Pending transactions (2):
##   + vetted txs that are ready to go into a block
##   + accepted against minimum fee check and other parameters (if any)
##   + transactions are marked `txItemPending`
##   + re-org or other events may send them back to queued
##
## * Staged transactions (3):
##   + all transactions to be placed and inclusded in block
##   + transactions are marked `txItemStaged`
##   + re-org or other events may send txs back to queued(1) state
##
## Tip
## ---
##
## * Rejected transactions (4):
##   + terminal state (waste basket), auto deleted (fifo with max size)
##   + accessible while not pushed out (by newer rejections) from the fifo
##   + transactions are marked with non-zero `reason` code
##

import
  ./tx_pool/[tx_dbhead, tx_desc, tx_info, tx_item, tx_job],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tabs/[tx_itemid, tx_leaf],
  ./tx_pool/tx_tasks,
  ./tx_pool/tx_tasks/[tx_add_tx, tx_staged_items, tx_pending_items],
  chronicles,
  chronos,
  eth/[common, keys],
  stew/results

export
  TxItemRef,
  TxItemStatus,
  TxJobDataRef,
  TxJobID,
  TxJobItemApply,
  TxJobKind,
  TxPoolRef,
  TxTabsStatsCount,
  results,
  tx_desc.init,
  tx_desc.startDate,
  tx_info,
  tx_item.effGasTip,
  tx_item.gasTipCap,
  tx_item.itemID,
  tx_item.info,
  tx_item.local,
  tx_item.sender,
  tx_item.status,
  tx_item.timeStamp,
  tx_item.tx

{.push raises: [Defect].}

logScope:
  topics = "tx-pool"

# ------------------------------------------------------------------------------
# Private functions: tasks processor
# ------------------------------------------------------------------------------

proc processJobs(xp: TxPoolRef): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Job queue processor
  ##
  ## Restrictions:
  ## * only one instance of `processJobs()` must be run at a time
  ## * variable `xp.dirtyPending` must not be accessed outside this function

  var
    rc: Result[TxJobPair,void]
    updatePending = xp.dirtyPending # locked parameter
    updateStaged = xp.dirtyStaged   # locked parameter

  xp.byJobExclusively:
    rc = xp.byJob.first

  while rc.isOK:
    let task = rc.value
    case task.data.kind
    of txJobNone:
      # No action
      discard

    of txJobAbort:
      # Stop processing and flush job queue (including the current one)
      xp.byJob.clear
      break

    of txJobAddTxs:
      # Add txs => queued(1), pending(2), or rejected(4) (see comment
      # on top of this source file for details.)
      var args = task.data.addTxsArgs
      for tx in args.txs.mitems:
        xp.txDBExclusively:
          xp.addTx(tx, args.local, args.info)
      updatePending = true # change may affect `pending` items
      updateStaged = true  # change may affect `staged` items

    of txJobApplyByLocal:
      # Apply argument function to all `local` or `remote` items.
      let args = task.data.applyByLocalArgs
      xp.txRunCallBack:
        xp.txDBExclusively:
          # core/tx_pool.go(1681): func (t *txLookup) Range(f func(hash ..
          for item in xp.txDB.byItemID.eq(args.local).walkItems:
            if not args.apply(item):
              break

    of txJobApplyByStatus:
      # Apply argument function to all `status` items.
      let args = task.data.applyByStatusArgs
      xp.txRunCallBack:
        xp.txDBExclusively:
          for itemList in xp.txDB.byStatus.incItemList(args.status):
            for item in itemList.walkItems:
              if not args.apply(item):
                break

    of txJobApplyByRejected:
      # Apply argument function to all `rejected` items.
      let args = task.data.applyByRejectedArgs
      xp.txRunCallBack:
        xp.txDBExclusively:
          for item in xp.txDB.byRejects.walkItems:
            if not args.apply(item):
              break

    of txJobEvictionInactive:
      # Move transactions older than `xp.lifeTime` to the waste basket.
      xp.txDBExclusively:
        xp.deleteExpiredItems(xp.lifeTime)

    of txJobFlushRejects:
      # Deletes at most the `maxItems` oldest items from the waste basket.
      let args = task.data.flushRejectsArgs
      xp.txDBExclusively:
        discard xp.txDB.flushRejects(args.maxItems)

    of txJobMoveRemoteToLocals:
      # For given account, remote transactions are migrated to local
      # transactions.
      let args = task.data.moveRemoteToLocalsArgs
      xp.txDBExclusively:
        discard xp.reassignRemoteToLocals(args.account)

    of txJobSetBaseFee:
      # New base fee (implies database reorg). Note that after changing the
      # `baseFee`, most probably a re-org should take place (e.g. invoking
      # `txJobUpdatePending`)
      let args = task.data.setBaseFeeArgs
      xp.txDB.baseFee = args.price     # cached value, change implies re-org
      xp.txDBExclusively:              # synchronised access
        xp.dbHead.baseFee = args.price # representative value
      updatePending = true # change may affect `pending` items
      updateStaged = true  # change may affect `staged` items

    of txJobSetHead: # FIXME: tbd
      # Change the insertion block header. This call might imply
      # re-calculating all current transaction states.
      discard

    of txJobUpdatePending:
      # For all items `queued` and `pending` items, re-calculate the status. If
      # the `force` flag is set, re-calculation is done even though the change
      # flags remained unset.
      let args = task.data.updatePendingArgs
      if updatePending or args.force or xp.dirtyPending:
        xp.txDBExclusively:
          xp.pendingItemsUpdate
        xp.dirtyPending = false
        updatePending = false # changes commited
        updateStaged = true  # change may affect `staged` items

    of txJobUpdateStaged:
      # For all `pending` and `staged` items, re-calculate the status.  If
      # the `force` flag is set, re-calculation is done even though the change
      # flags remained unset. If there was no change in the `minTipPrice` and
      # `minFeePrice`, only re-assign from `pending` and `staged`.
      let args = task.data.updateStagedArgs
      if args.force or xp.minFeePriceChanged or xp.minTipPriceChanged:
        xp.txDBExclusively:
          xp.stagedItemsReorg
        discard xp.minFeePriceChanged # reset change detect
        discard xp.minTipPriceChanged # reset change detect
        xp.dirtyStaged = false
        updateStaged = false
      elif updateStaged or xp.dirtyStaged:
        xp.txDBExclusively:
          xp.stagedItemsAppend
        xp.dirtyStaged = false
        updateStaged = false

    # End case/switch
    result.inc

    # Remove the current job and get the next one. The current job could
    # not be removed earlier because there might be the `jobCommit()`
    # funcion waiting for it to have finished.
    xp.byJobExclusively:
      xp.byJob.dispose(task.id)
      rc = xp.byJob.first

  # End while

  # Update flags, will trigger jobs when loop is invoked next
  if updatePending:
    xp.dirtyPending = true
  if updateStaged:
    xp.dirtyStaged = true

# ------------------------------------------------------------------------------
# Public functions, task manager, pool action1 serialiser
# ------------------------------------------------------------------------------

proc nJobsWaiting*(xp: TxPoolRef): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Return the number of jobs currently unprocessed, waiting.
  xp.byJobExclusively:
    result = xp.byJob.len

proc job*(xp: TxPoolRef; job: TxJobDataRef): TxJobID
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## Add a new job to the queue (but do not start the commit loop.)
  xp.byJobExclusively:
    result = xp.byJob.add(job)

proc jobCommit*(xp: TxPoolRef) {.async.} =
  ## This function processes all jobs currently on the queue. Jobs added
  ## while this function is active are left on the queue and need to be
  ## processed with another instance of `jobCommit()`.

  # Wait until the next batch is ready. This needs to be waited for as
  # there might be another job running running some older jobs. The event
  # is activated when the latest chunk can be processed.
  await xp.byJob.waitLatest

  # Run jobs processor. It does not matter if this fails. In that case, some
  # other `jobCommit()` is running processing at least the current batch.
  if xp.uniqueAccessCommitLoop:
    # all jobs will be processed in foreground, release afterwards
    let nJobs = xp.processJobs
    debug "processed jobs",
      nJobs
    xp.releaseAccessCommitLoop

# ------------------------------------------------------------------------------
# Public functions, immediate actions (not queued as a job.)
# ------------------------------------------------------------------------------

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
# core/tx_pool.go(1728): func (t *txLookup) Count() int {
# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
proc count*(xp: TxPoolRef): TxTabsStatsCount
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the current pool stats: the number of local, remote,
  ## pending, queued, etc. transactions.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    result = xp.txDB.statsCount


# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
proc getItem*(xp: TxPoolRef; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns a transaction if it is contained in the pool.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    result = xp.txDB.byItemID.eq(hash)


# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc getAccounts*(xp: TxPoolRef; local: bool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered `local` or `remote` (i.e.
  ## the have txs of that kind) depending on request arguments.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    result = xp.collectAccounts(local)


# core/tx_pool.go(435): func (pool *TxPool) GasPrice() *big.Int {
proc getMinFeePrice*(xp: TxPoolRef): uint64
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Get the current gas price enforced by the transaction pool.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minFeePrice


# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinFeePrice*(xp: TxPoolRef; val: uint64): uint64
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the minimum price required by the transaction pool for txs to be
  ## staged. Increasing it will remove some transactions when the stage is
  ## re-built.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minFeePrice = val
  xp.dirtyStaged = false


proc getMinTipPrice*(xp: TxPoolRef): uint64
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Similar to `getMinFeePrice`
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minTipPrice


# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinTipPrice*(xp: TxPoolRef; val: uint64): uint64
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Similar to `setMinFeePrice`
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minTipPrice = val
  xp.dirtyStaged = false


proc getBaseFee*(xp: TxPoolRef): uint64
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Get the `baseFee` implying the price list valuation and order.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    result = xp.txDB.baseFee


proc setMaxRejects*(xp: TxPoolRef; size: int)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the size of the waste basket. This setting becomes effective with
  ## the next move of an item into the waste basket.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    xp.txDB.maxRejects = size


proc setStatus*(xp: TxPoolRef; item: TxItemRef; status: TxItemStatus)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Change/update the status of the transaction item.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  if status != item.status:
    xp.txCallBackOrDBExclusively:
      discard xp.txDB.reassign(item, status)
    if status == txItemPending or status == txItemPending:
      xp.dirtyPending = true # change may affect `pending` items
      xp.dirtyStaged = true  # change may affect `staged` items


proc rejectItem*(xp: TxPoolRef; item: TxItemRef; reason: TxInfo)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move item to wastebasket.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    discard xp.txDB.reject(item, reason)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
##  .                .                         .
##  .   <Job queue>  .   <Accounting system>   .   <Tip/waste disposal>
##  .                .                         .
##  .                .         +-----------+   .
##  .     +------------------> | queued(1) | -------------+
##  .     |          .         +-----------+   .          |
##  .     |          .           |   ^   ^     .          |
##  .     |          .           V   |   |     .          |
##  .     |          .   +------------+  |     .          |
##  .  enter(0) -------> | pending(2) |  |     .          |
##  .     |          .   +------------+  |     .          |
##  .     |          .     |     |       |     .          |
##  .     |          .     |     V       |     .          |
##  .     |          .     |   +-----------+   .          |
##  .     |          .     |   | staged(3) | -----------+ |
##  .     |          .     |   +-----------+   .        | |
##  .     |          .     |                   .        v v
##  .     |          .     |                   .    +----------------+
##  .     |          .     +----------------------> |  rejected(4)   |
##  .     +---------------------------------------> | (waste basket) |
##  .                .                         .    +----------------+
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
  ./tx_pool/[tx_dbhead, tx_desc, tx_info, tx_item, tx_job, tx_tabs, tx_tasks],
  ./tx_pool/tx_tabs/[tx_itemid, tx_leaf],
  chronicles,
  stew/results

export
  TxItemRef,
  TxItemStatus,
  TxJobDataRef,
  TxJobFlushRejectsReply,
  TxJobGetAccountsReply,
  TxJobItemGetReply,
  TxJobGetPriceReply,
  TxJobID,
  TxJobItemApply,
  TxJobKind,
  TxJobMoveRemoteToLocalsReply,
  TxJobStatsCountReply,
  TxPool,
  TxTabsStatsCount,
  results,
  tx_desc.init,
  tx_desc.gasPrice,
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

proc processJobs(xp: var TxPool): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Job queue processor
  ##
  ## Restrictions:
  ## * only one instance of `processJobs()` must be run at a time
  ## * variable `xp.dirtyPending` must not be access outside this function

  var rc = xp.byJob.fetch
  while rc.isOK:
    let task = rc.value
    case task.data.kind
    of txJobNone:
      discard

    of txJobAbort:
      xp.byJob.init
      break

    of txJobAddTxs:
      # Add txs => queued(1), pending(2), or rejected(4) (see somment
      # on to of page for details.
      var args = task.data.addTxsArgs
      xp.addTxs(args.txs, args.local, args.info)

    of txJobApplyByLocal:
      # core/tx_pool.go(1681): func (t *txLookup) Range(f func(hash ..
      let args = task.data.applyByLocalArgs
      for item in xp.txDB.byItemID.eq(args.local).walkItems:
        if not args.apply(item):
          break
      xp.dirtyPending = true

    of txJobApplyByStatus:
      let args = task.data.applyByStatusArgs
      for itemList in xp.txDB.byStatus.incItemList(args.status):
        for item in itemList.walkItems:
          if not args.apply(item):
            break
      xp.dirtyPending = true

    of txJobApplyByRejected: ##\
      let args = task.data.applyByRejectedArgs
      for item in xp.txDB.byRejects.walkItems:
        if not args.apply(item):
          break

    of txJobEvictionInactive:
      xp.deleteExpiredItems(xp.lifeTime)

    of txJobFlushRejects:
      let
        args = task.data.flushRejectsArgs
        data = xp.txDB.flushRejects(args.maxItems)
      args.reply(deleted = data[0], remaining = data[1])

    of txJobGetBaseFee:
      let args = task.data.getBaseFeeArgs
      args.reply(price = xp.txDB.baseFee)

    of txJobGetGasPrice:
      let args = task.data.getGasPriceArgs
      args.reply(price = xp.gasPrice)

    of txJobGetAccounts:
      let args = task.data.getAccountsArgs
      args.reply(accounts = xp.collectAccounts(args.local))

    of txJobItemGet:
      let
        args = task.data.itemGetArgs
        rc = xp.txDB.byItemID.eq(args.itemID)
      if rc.isOK:
        args.reply(item = rc.value)
      else:
        args.reply(item = nil)

    of txJobItemSetStatus:
      let args = task.data.itemSetStatusArgs
      discard xp.txDB.reassign(args.item, args.status)
      xp.dirtyPending = true

    of txJobMoveRemoteToLocals:
      let args = task.data.moveRemoteToLocalsArgs
      args.reply(moved = xp.reassignRemoteToLocals(args.account))
      xp.dirtyPending = true

    of txJobRejectItem:
      let args = task.data.rejectItemArgs
      discard xp.txDB.reject(args.item, args.reason)
      xp.dirtyPending = true

    of txJobSetBaseFee:
      let args = task.data.setBaseFeeArgs
      xp.txDB.baseFee = args.price   # cached value, change implies re-org
      xp.dbHead.baseFee = args.price # representative value
      xp.dirtyPending = true

    of txJobSetGasPrice:
      let args = task.data.setGasPriceArgs
      var curPrice = xp.gasPrice
      xp.updateGasPrice(curPrice = curPrice, newPrice = args.price)
      xp.gasPrice = curPrice
      xp.dirtyPending = true

    of txJobSetHead: # FIXME: tbd
      discard

    of txJobSetMaxRejects:
      let args = task.data.setMaxRejectsArgs
      xp.txDB.maxRejects = args.size

    of txJobStatsCount:
      let args = task.data.statsCountArgs
      args.reply(status = xp.txDB.statsCount)

    of txJobUpdatePending:
      let args = task.data.updatePendingArgs
      if xp.dirtyPending or args.force:
        xp.updatePending(xp.dbHead)
        xp.dirtyPending = false

    # End case
    result.inc

    if task.data.hiatus:
      break

    # Get nxt job
    rc = xp.byJob.fetch


proc runJobSerialiser(xp: var TxPool): Result[int,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Executes jobs in the queue (if any.) The function returns the
  ## number of executes jobs.

  var alreadyRunning = true
  xp.byJob.doExclusively:
    if not xp.commitLoop:
      alreadyRunning = false
      xp.commitLoop = true

  if alreadyRunning:
    return err()

  let nJobs = xp.processJobs
  xp.byJob.doExclusively:
    xp.commitLoop = false

  ok(nJobs)

# ------------------------------------------------------------------------------
# Public functions, task manager, pool action serialiser
# ------------------------------------------------------------------------------

proc nJobsWaiting*(xp: var TxPool): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Return the number of jobs currently unprocessed, waiting.
  xp.byJob.len

proc job*(xp: var TxPool; job: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Add a new job to the queue (but do not start the commit loop.)
  xp.byJob.add(job)

proc jobCommit*(xp: var TxPool; job: TxJobDataRef)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Add a new job to the queue and start the commit loop (unless running
  ## already.)
  ##
  ## :FIXME:
  ##   currently this function runs in foreground but needs to be
  ##   made ready to run on the chronos process handler.
  job.hiatus = true
  let jobID = xp.job(job)
  if xp.runJobSerialiser.isErr:
    raiseAssert "background processing not implemented yet"
  while xp.byJob.hasKey(jobID):
    discard xp.runJobSerialiser

proc jobCommit*(xp: var TxPool)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Process current elements of the job queue
  xp.jobCommit(TxJobDataRef(
    kind: txJobNone))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
## * Support `local` transactions (currently unsupported.) Foe now, all txs
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
  std/[times],
  ../db/db_chain,
  ./tx_pool/[tx_dbhead, tx_info, tx_item, tx_job, tx_tabs, tx_tasks],
  chronicles,
  eth/[common, keys],
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
  TxTabsStatsCount,
  results,
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

const
  txPoolLifeTime = initDuration(hours = 3)
  txPriceLimit = 1

  # Journal:   "transactions.rlp",
  # Rejournal: time.Hour,
  #
  # PriceBump:  10,
  #
  # AccountSlots: 16,
  # GlobalSlots:  4096 + 1024, // urgent + floating queue capacity with
  #                            // 4:1 ratio
  # AccountQueue: 64,
  # GlobalQueue:  1024,

type
  TxPool* = object of RootObj ##\
    ## Transaction pool descriptor
    dbHead: TxDbHead     ## block chain state
    startDate: Time      ## Start date (read-only)

    gasPrice: uint64     ## Gas price enforced by the pool
    lifeTime*: Duration  ## Maximum amount of time non-executable txs are queued

    byJob: TxJob         ## Job batch list
    txDB: TxTabsRef      ## Transaction lists & tables

    commitLoop: bool     ## Sentinel, set while commit loop is running
    dirtyPending: bool   ## Pending queue needs update

    # locals: seq[EthAddress] ## Addresses treated as local by default
    # noLocals: bool          ## May disable handling of locals
    # priceLimit: GasInt      ## Min gas price for acceptance into the pool
    # priceBump: uint64       ## Min price bump percentage to replace an already
    #                         ## existing transaction (nonce)

{.push raises: [Defect].}

logScope:
  topics = "tx-pool"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc utcNow: Time =
  now().utc.toTime

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
      xp.txDB.addTxs(xp.dbHead, args.txs, args.local, args.info)

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
      xp.txDB.deleteExpiredItems(xp.lifeTime)

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
      args.reply(accounts = xp.txDB.collectAccounts(args.local))

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
      args.reply(moved = xp.txDB.reassignRemoteToLocals(args.account))
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
      xp.txDB.updateGasPrice(curPrice = xp.gasPrice, newPrice = args.price)
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
        xp.txDB.updatePending(xp.dbHead)
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
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: var TxPool; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.dbHead.init(db)
  xp.txDB = init(type TxTabsRef, xp.dbHead.baseFee)
  xp.byJob.init

  xp.startDate = utcNow()
  xp.gasPrice = txPriceLimit
  xp.lifeTime = txPoolLifeTime

proc init*(T: type TxPool; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  result.init(db)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc startDate*(xp: var TxPool): Time {.inline.} =
  ## Getter
  xp.startDate

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
# Public functions, debugging (not serialised)
# ------------------------------------------------------------------------------

proc txDB*(xp: var TxPool): TxTabsRef {.inline.} =
  ## Getter, Transaction lists & tables (for debugging only)
  xp.txDB

proc dbHead*(xp: var TxPool): TxDbHead {.inline.} =
  ## Getter, block chain DB
  xp.dbHead

proc verify*(xp: var TxPool): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.

  block:
    let rc = xp.byJob.verify
    if rc.isErr:
      return rc

  xp.txDB.verify

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

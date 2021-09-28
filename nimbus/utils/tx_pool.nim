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

from chronos import
  AsyncLock,
  AsyncLockError,
  acquire,
  newAsyncLock,
  release,
  waitFor

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
  TxJobSetHeadReply,
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
  txGasTarget = 15_000_000

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
    gasTarget: GasInt    ## Packing target
    lifeTime*: Duration  ## Maximum amount of time non-executable txs are queued

    byJob: TxJob         ## Job batch list
    txDB: TxTabsRef      ## Transaction lists & tables

    asyncLock: AsyncLock ## Protects the `commitLoop` descriptor
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

proc lock(xp: var TxPool) {.inline, raises: [Defect,CatchableError].} =
  ## Lock descriptor
  waitFor xp.asyncLock.acquire

proc unLock(xp: var TxPool) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor
  xp.asyncLock.release

template doExclusively(xp: var TxPool; action: untyped) =
  ## Handy helper
  xp.lock
  action
  xp.unlock

# ------------------------------------------------------------------------------
# Private helpers for tasks processor
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private functions: tasks processor
# ------------------------------------------------------------------------------

proc processJobs(xp: var TxPool): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  var rc: Result[TxJobPair,void]
  xp.doExclusively:
    rc = xp.byJob.fetch

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
      xp.txDB.addTxs(xp.dbHead, xp.gasTarget, args.txs, args.local, args.info)

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
      xp.txDB.baseFee = args.price
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
        xp.txDB.rebuildPendingQueue
        xp.dirtyPending = false

    # End case
    result.inc

    if task.data.hiatus:
      break

    # only the job queue will be accessed locked
    xp.doExclusively:
      rc = xp.byJob.fetch


proc runJobSerialiser(xp: var TxPool): Result[int,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Executes the jobs in the queue (if any.) The function returns the
  ## number of executes jobs.
  # make sure this commit loop is the only one running
  var otherInstanceRunning = false

  # initalise first job and lock commit loop
  xp.doExclusively:
    if xp.commitLoop:
      otherInstanceRunning = true
    else:
      xp.commitLoop = true

  # no way, sombody else is taking care of the jobs
  if otherInstanceRunning:
    return err()

  let nJobs = xp.processJobs

  xp.doExclusively:
    xp.commitLoop = false
  ok(nJobs)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: var TxPool; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.dbHead.init(db)
  xp.txDB = init(type TxTabsRef)

  xp.startDate = utcNow()
  xp.gasPrice = txPriceLimit
  xp.gasTarget = txGasTarget
  xp.lifeTime = txPoolLifeTime

  xp.asyncLock = newAsyncLock()


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
  xp.doExclusively:
    result = xp.byJob.len

proc job*(xp: var TxPool; job: TxJobDataRef): TxJobID
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Add a new job to the queue (but do not start the commit loop.)
  xp.doExclusively:
    result = xp.byJob.add(job)

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

# DefaultTxPoolConfig contains the default configurations for the transaction
# pool.

# sanitize checks the provided user configurations and changes anything that's
# unreasonable or unworkable.
#func (config *TxPoolConfig) sanitize() TxPoolConfig

# TxPool contains all currently known transactions. Transactions
# enter the pool when they are received from the network or submitted
# locally. They exit the pool when they are included in the blockchain.
#
# The pool separates processable transactions (which can be applied to the
# current state) and future transactions. Transactions move between those
# two states over time as they are received and processed.
#type TxPool struct

# NewTxPool creates a new transaction pool to gather, sort and filter inbound
# transactions from the network.
#func NewTxPool(
#  config TxPoolConfig, chainconfig *params.ChainConfig, chain blockChain)
#    *TxPool

# Stop terminates the transaction pool.
#func (pool *TxPool) Stop()

# SubscribeNewTxsEvent registers a subscription of NewTxsEvent and
# starts sending event to the given channel.
#func (pool *TxPool) SubscribeNewTxsEvent(ch chan<- NewTxsEvent)
#  event.Subscription

# -- // This is like AddRemotes, but waits for pool reorganization. Tests use
# -- // this method.
# -- func (pool *TxPool) AddRemotesSync(txs []*types.Transaction) []error

# -- // Get returns a transaction if it exists in the lookup, or nil if not
# -- // found.
# -- func (t *txLookup) Get(hash common.Hash) *types.Transaction {
#
# -- // Slots returns the current number of slots used in the lookup.
# -- func (t *txLookup) Slots() int
#
# -- // Add adds a transaction to the lookup.
# -- func (t *txLookup) Add(tx *types.Transaction, local bool)
#
# -- // Remove removes a transaction from the lookup.
# -- func (t *txLookup) Remove(hash common.Hash)


#[
import
  std/sequtils,
  ./slst

# core/tx_pool.go(1713): func (t *txLookup) GetLocal(hash common.Hash) ..
proc getLocal*(xp: var TxPool; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns a local transaction if it exists.
  xp.txDB.byItemID.eq(local = true).eq(hash)

# core/tx_pool.go(1721): func (t *txLookup) GetRemote(hash common.Hash) ..
proc getRemote*(xp: var TxPool; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns a remote transaction if it exists.
  xp.txDB.byItemID.eq(local = false).eq(hash)

# core/tx_pool.go(1813): func (t *txLookup) RemotesBelowTip(threshold ..
proc remotesBelowTip*(xp: var TxPool; threshold: GasInt): seq[Hash256]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Finds all remote transactions below the given tip threshold.
  xp.txDB.getRemotesBelowTip(threshold)

# core/tx_pool.go(465): func (pool *TxPool) Nonce(addr common.Address) uint64 {
proc nonce*(xp: var TxPool; sender: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns the next nonce of an account, with all transactions executable
  ## by the pool already applied on top.
  let rc = xp.txDB.bySender.eq(sender).any.le(AccountNonce.high)
  if rc.isOK:
    return rc.value.key + 1

# core/tx_pool.go(497): func (pool *TxPool) Content() (map[common.Address]..
proc content*(xp: var TxPool): seq[(seq[TxItemRef],seq[TxItemRef])]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the data content of the transaction pool, returning the pair of
  ## transaction queues `(pending,queued)`, grouped by account and sorted
  ## by nonce.
  for schedList in xp.txDB.bySender.walkSchedList:
    var pList: seq[TxItemRef]
    for itemList in schedList.walkItemList(txItemPending):
      for item in itemList.walkItems:
        pList.add item.dup
    var qList: seq[TxItemRef]
    for itemList in schedList.walkItemList(txItemQueued):
      for item in itemList.walkItems:
        qList.add item.dup
    result.add (pList,qList)

# core/tx_pool.go(514): func (pool *TxPool) ContentFrom(addr common.Address) ..
proc contentFrom*(xp: var TxPool;
                  sender: EthAddress): (seq[TxItemRef],seq[TxItemRef])
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves the data content of the transaction pool, returning the pair of
  ## transaction queues `(pending,queued)` of this address, grouped by nonce.
  let rcSched = xp.txDB.bySender.eq(sender)
  if rcSched.isOK:
    let rcPending = rcSched.eq(txItemPending)
    if rcPending.isOK:
      for itemList in rcPending.value.data.walkItemList:
        result[0].add toSeq(itemList.walkItems)
    let rcQueued = rcSched.eq(txItemQueued)
    if rcQueued.isOK:
      for itemList in rcQueued.value.data.walkItemList:
        result[1].add toSeq(itemList.walkItems)

# core/tx_pool.go(536): func (pool *TxPool) Pending(enforceTips bool) (map[..
proc pendingItems*(xp: var TxPool; enforceTips = false): seq[seq[TxItemRef]]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## The function retrieves all currently processable transaction items,
  ## grouped by origin account and sorted by nonce. The returned transaction
  ## items are copies and can be freely modified.
  ##
  ## The `enforceTips` parameter can be used to do an extra filtering on the
  ## pending transactions and only return those whose **effective** tip is
  ## large enough in the next pending execution environment.
  for schedList in xp.txDB.bySender.walkSchedList:
    var list: seq[TxItemRef]
    for itemList in schedList.walkItemList(txItemPending):
      for item in itemList.walkItems:
        if item.local or
           not enforceTips or
           xp.gasPrice <= item.effectiveGasTip:
          list.add item.dup
    if 0 < list.len:
      result.add list

# core/tx_pool.go(975): func (pool *TxPool) Status(hashes []common.Hash) ..
proc status*(xp: var TxPool; hashes: openArray[Hash256]): seq[TxItemStatus]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Returns the status (unknown/pending/queued) of a batch of transactions
  ## identified by their hashes.
  result.setLen(hashes.len)
  for n in 0 ..< hashes.len:
    let rc = xp.txDB.byItemID.eq(hashes[n])
    if rc.isOK:
      result[n] = rc.value.status


# core/tx_pool.go(1681): func (t *txLookup) Range(f func(hash common.Hash, ..
iterator rangeFifo*(xp: var TxPool; local: varargs[bool]): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Local/remote transaction queue walk/traversal: oldest first
  ##
  ## :Note:
  ##    When running in a loop it is ok to delete the current item and all
  ##    the items already visited. Items not visited yet must not be deleted.
  for isLocal in local:
    var rc = xp.txDB.byItemID.eq(isLocal).first
    while rc.isOK:
      let item = rc.value.data
      rc = xp.txDB.byItemID.eq(isLocal).next(item.itemID)
      yield item

iterator rangeLifo*(xp: var TxPool; local: varargs[bool]): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Local or remote transaction queue walk/traversal: oldest last
  ##
  ## See also the **Note* at the comment for `rangeFifo()`.
  for isLocal in local:
    var rc = xp.txDB.byItemID.eq(isLocal).last
    while rc.isOK:
      let item = rc.value.data
      rc = xp.txDB.byItemID.eq(isLocal).prev(item.itemID)
      yield item

]#

proc txDB*(xp: var TxPool): TxTabsRef {.inline.} =
  ## Getter, Transaction lists & tables (for debugging only)
  xp.txDB

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

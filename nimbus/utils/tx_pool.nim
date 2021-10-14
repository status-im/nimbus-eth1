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
## * Support `local` transactions (currently unsupported and ignored.) For
##   now, all txs are considered from `remote` accounts.
## * There is no handling of zero gas price transactions yet
## * Clarify whether there are legacy transactions possible with post-London
##   chain blocks.
## * Automatically move jobs to the waste basket if their life time has expired.
## * Implement re-positioning the current insertion point, typically the head
##   of the block chain.
##
##
## Transaction state diagram:
## --------------------------
## ::
##  .                   .                          .
##  .     <Job queue>   .   <Accounting system>    .   <Tip/waste disposal>
##  .                   .                          .
##  .                   .          +-----------+   .
##  .        +-------------------> | queued(1) | ------------+
##  .        |          .          +-----------+   .         |
##  .        |          .            |  ^    ^     .         |
##  .        |          .            V  |    |     .         |
##  .        |          .    +------------+  |     .         |
##  .  --> enter(0) -------> | pending(2) |  |     .         |
##  .        |          .    +------------+  |     .         |
##  .        |          .      |     |       |     .         |
##  .        |          .      |     V       |     .         |
##  .        |          .      |   +-----------+   .         |
##  .        |          .      |   | staged(3) | ----------+ |
##  .        |          .      |   +-----------+   .       | |
##  .        |          .      |                   .       v v
##  .        |          .      |                   .   +----------------+
##  .        |          .      +---------------------> |  rejected(4)   |
##  .        +---------------------------------------> | (waste basket) |
##  .                   .                          .   +----------------+
##
## Terminology
## ----------
## There are the job *queue* and the queued, pending, and stage *buckets*
## and the *waste basket*. These names are (not completely) arbitrary. Even
## though all are more or less implemented as queues with some sort of random
## access the names *bucket* and *basket* should indicate some sort of usage.
##
## Job Queue
## ---------
## * Transactions entering the system (0):
##   + txs are added to the job queue an processed sequentially
##   + when processed, they are moved
##
## Accounting system
## -----------------
## * Queued transactions bucket (1):
##   + It holds txs tested all right but not ready to fit into a block
##   + These txs are stored with meta-data and marked `txItemQueued`
##   + Txs have a `nonce` which is not smaller than the nonce value of the tx
##     sender account. If it is greater than the one of the tx sender account,
##     the predecessor nonce, i.e. `nonce-1` is in the database.
##
## * Pending transactions bucket (2):
##   + It holds vetted txs that are ready to go into a block.
##   + Txs are accepted against minimum fee check and other parameters (if any)
##   + Txs are marked `txItemPending`
##   + Txs have a `nonce` equal to the current value of the tx sender account.
##   + Re-org or other events may send them to queued(1) or pending(3) bucket
##
## * Staged transactions bucket (3):
##   + All transactions are to be placed and inclusded in a block
##   + Transactions are marked `txItemStaged`
##   + Re-org or other events may send txs back to queued(1) bucket
##
## Tip/waste basket
## ----------------
## * Rejected transactions (4):
##   + terminal state (waste basket), auto deleted (fifo with max size)
##   + accessible while not pushed out (by newer rejections) from the fifo
##   + txs are marked with non-zero `reason` code
##
## Interaction of components
## -------------------------
## The idea is that there are concurrent instances feeding transactions into
## the job queue via `enter(0)`. The system uses the `{.async.}` paradigm,
## threads are unsupported (mixing asyncs with threads failed in some test due
## to unwanted duplication of *event* semaphores.) The job queue is processed
## on demand, typically when a result is required.
##
## A piece of code using the pool would look as follows:
## ::
##    # see also unit test examples, e.g. "Staging and packing txs .."
##    var db: BaseChainDB
##    var tx: Transaction
##    ..
##
##    var xq = TxPoolRef.init(db)         # initialise tx-pool
##    ..
##
##    xq.pjaAddTx(tx, info = "test data") # stash transactions and hold it
##    ..                                  # .. on the job queue for a moment
##
##    xq.pjaUpdateStaged                  # stash task to assemble staged bucket
##    ..
##
##    xq.nextBlock                        # assemble eth block
##
##    let newBlock = xq.getBlock          # new block with transactions
##
##
## Discussion of example
## ~~~~~~~~~~~~~~~~~~~~~
## From the example, transactions are collected via `pjaAddTx()` and added to
## a batch of jobs to be done some time later.
##
## Following, another job is added to the batch via `pjaUpdateStaged()`
## requesting to fill the *staged* bucket after the added jobs have been
## processed.
##
## In this example, not until `nextBlock()` is invoked, the batch of jobs in
## the *job queue* will be processed. This directive will implicitly call
## `jobCommit()` which invokes the job processor on the batch queue. So the
## `nextBlock()` cleans up all of the job queue and pulls as many transactions
## as possible from the *staged* bucket, packs them into the block up until it
## is full and disposes the remaining transaction wrappers into the waste
## basket (so they remain still accessible for a while.)
##
## Finally. `getBlock()` retrieves the last block stored in the descriptor
## cache which will be overwritten not until `nextBlock()` is invoked, again.
##
## Processing the job queue
## ~~~~~~~~~~~~~~~~~~~~~~~~
## Although the job queue can be processed any time, a lazy approach is the
## most convenient. nevertheless, the job processor can be triggered any time
## concurrently with the  `jobCommit()` directive. The directive guarantees
## that all jobs currently on the queue will be processed, but not the ones
## added while processing. Also, processing might run on another async task.
## So when `jobCommit()` returns, the job processor might still run.
##
## Transactions and buckets
## ~~~~~~~~~~~~~~~~~~~~~~~~
## Transactions are wrapped into metadata (called `item`) and kept in a
## database. Any *bucket* or *waste basket* is represented by a pair of labels 
## `(<status>,<reason>)` where `<status>` is a *bucket* label `queued`,
## `pending`, or `staged`, and `<reason>` is sort of an error code. An `item`
## with reason code different from `txInfoOk` (aka zero) is from the *waste
## basket*, otherwise it is in one of the *buckets*.
##
## The management of the `items` is supported by the tables that make up the
## database.
##
## Moving transactions around
## ~~~~~~~~~~~~~~~~~~~~~~~~~~
## Transactions are *moved* between *buckets* and *waste basket* (which is a
## terminal state). These movements take places asynchronously. Incoming
## invalid transactions are immediately placed in the *waste basket*. All other
## transactions are handled in tasks controlled by the following parameters
## that affect how transactions are shuffled around.
##
## priceBump
##   There can be only one transaction in the database for the same `sender`
##   account and `nonce` value. When adding a transaction with the same
##   (`sender`, `nonce`) pair, the new transaction will replace the current one
##   if it has a gas price which is at least `priceBump` per cent higher.
##
## gasLimit
##   Taken or derived from the current block chain head, incoming txs that
##   exceed this gas limit are stored into the queued bucket (waiting for the
##   next cycle.)
##
## baseFee
##   Applicable to post-London only and compiled from the current block chain
##   head. Incoming txs with smaller `maxFee` values are stored in the queued
##   bucket (waiting for the next cycle.) For practical reasons, `baseFee` is
##   zero for pre-London block chain states.
##
## minFeePrice, *optional*
##   Applies no EIP-1559 txs only. Txs are staged if `maxFee` is at least
##   that value.
##
## minTipPrice, *optional*
##   For EIP-1559, txs are staged if the expected tip (see `estimatedGasTip()`)
##   is at least that value. In compatibility mode for legacy txs, this
##   degenerates to `gasPrice - baseFee`.
##
## minPlGasPrice, *optional*
##   For pre-London or legacy txs, this parameter has precedence over
##   `minTipPrice`. Txs are staged if the `gasPrice` is at least that value.
##
## trgGasLimit, maxGasLimit
##   These parameters are derived from the current block chain head. They
##   limit how many blocks from the staged bucket can be packed into the body
##   of the new block.
##
## lifeTime
##   Older job can be purged from the system.
##
##

import
  ./keequ,
  ./tx_pool/[tx_dbhead, tx_desc, tx_info, tx_item, tx_job],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tabs/tx_leaf,
  ./tx_pool/tx_tasks,
  ./tx_pool/tx_tasks/[tx_add_tx,
                      tx_staged_items,
                      tx_pack_items,
                      tx_pending_items],
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
  TxPoolAlgoSelectorFlags,
  TxPoolRef,
  TxTabsStatsCount,
  results,
  tx_desc.init,
  tx_desc.startDate,
  tx_info,
  tx_item.GasPrice,
  tx_item.`<=`,
  tx_item.`<`,
  tx_item.effGasTip,
  tx_item.gasTipCap,
  tx_item.info,
  tx_item.itemID,
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
          xp.addTx(tx, args.info)
      updatePending = true # change may affect `pending` items
      updateStaged = true  # change may affect `staged` items

    of txJobApply:
      # Apply argument function to all `local` or `remote` items.
      let args = task.data.applyArgs
      xp.txRunCallBack:
        xp.txDBExclusively:
          # core/tx_pool.go(1681): func (t *txLookup) Range(f func(hash ..
          for item in xp.txDB.byItemID.nextValues:
            if not args.apply(item):
              break

    of txJobApplyByStatus:
      # Apply argument function to all `status` items.
      let args = task.data.applyByStatusArgs
      xp.txRunCallBack:
        xp.txDBExclusively:
          for item in xp.txDB.byStatus.incItemList(args.status):
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

    of txJobPackBlock:
      let args = task.data.packBlockArgs
      xp.txDBExclusively:
        xp.packItemsIntoBlock
      if args.sayReady:
        args.waitReady.fire

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
        updateStaged = false # changes commited
        updatePending = true # change may affect `pending` items
      elif updateStaged or xp.dirtyStaged:
        xp.txDBExclusively:
          xp.stagedItemsAppend
        xp.dirtyStaged = false
        updateStaged = false # changes commited

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


# core/tx_pool.go(435): func (pool *TxPool) GasPrice() *big.Int {
proc getMinFeePrice*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter for `minFeePrice`, the current gas fee enforced by the transaction
  ## pool for txs to be staged. This is an EIP-1559 only parameter (see
  ## `stage1559MinFee` strategy.)
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minFeePrice

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinFeePrice*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minFeePrice`. Increasing it might remove some post-London
  ## transactions when the `staged` bucket is re-built.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minFeePrice = val
  xp.dirtyStaged = false


proc getMinTipPrice*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter for `minTipPrice`, the current gas tip (or priority fee) enforced
  ## by the transaction pool. This is an EIP-1559 parameter but with a fall
  ## back legacy interpretation (see `stage1559MinTip` strategy.)
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minTipPrice

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinTipPrice*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minTipPrice`. Increasing it might remove some transactions
  ## when the `staged` bucket is re-built.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minTipPrice = val
  xp.dirtyStaged = false


proc getMinPlGasPrice*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter for `minPlGasPrice`, the current gas price enforced by the
  ## transaction pool. This is a pre-London parameter (see `stagedPlMinPrice`
  ## strategy.)
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minPlGasPrice

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinPlGasPrice*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minPlGasPrice`.  Increasing it might remove some legacy
  ## transactions when the `staged` bucket is re-built.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.minPlGasPrice = val
  xp.dirtyStaged = false


proc getBaseFee*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Get the `baseFee` implying the price list valuation and order.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    result = xp.txDB.baseFee

proc setBaseFee*(xp: TxPoolRef; baseFee: GasPrice; force = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, implies some re-org of the data base. If the argument `force` is
  ## set `true`, the base fee is set immediately, otherwise it is queued
  ## and execured when the next `jobCommit()` takes place
  discard xp.job(TxJobDataRef(
    kind:     txJobSetBaseFee,
    setBaseFeeArgs: (
      price:  baseFee)))
  if force:
    waitFor xp.jobCommit


proc setAlgoSelector*(xp: TxPoolRef; strategy: varArgs[TxPoolAlgoSelectorFlags])
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set strategy symbols on how to stage items.
  var args: set[TxPoolAlgoSelectorFlags]
  for w in strategy:
    args.incl(w)
  xp.algoSelect = args

proc setAlgoSelector*(xp: TxPoolRef; strategy: set[TxPoolAlgoSelectorFlags])
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  xp.algoSelect = strategy

proc getStageSelector*(xp: TxPoolRef): set[TxPoolAlgoSelectorFlags]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Return strategy symbols on how to stage items.
  xp.algoSelect


proc getBlock*(xp: TxPoolRef): EthBlock
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves the last assembled block from the cache
  xp.ethBlock

proc nextBlock*(xp: TxPoolRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Assembles a new block from the `staged` bucket and returns the maximum
  ## block size retrieved by summing up `gasLimit` entries of the included
  ## txs.
  let req = TxJobDataRef(
    kind:        txJobPackBlock,
    packBlockArgs: (
      sayReady:  true,
      waitReady: newAsyncEvent()))
  discard xp.job(req)

  # Note that `xp.jobCommit` only guarantees that the job `req` will eventually
  # be completed but as this happens asynchronously, it might happen somewhat
  # later.
  waitFor xp.jobCommit

  # So waiting for an event makes sense.
  waitFor req.packBlockArgs.waitReady.wait

  xp.ethBlockSize

# ------------------------------------------------------------------------------
# Public functions, more immediate actions deemed not so important yet
# ------------------------------------------------------------------------------

proc setMaxRejects*(xp: TxPoolRef; size: int)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the size of the waste basket. This setting becomes effective with
  ## the next move of an item into the waste basket.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    xp.txDB.maxRejects = size

# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc getAccounts*(xp: TxPoolRef; local: bool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered `local` or `remote` (i.e.
  ## the have txs of that kind) depending on request arguments.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    if local:
      result = xp.txDB.locals
    else:
      result = xp.txDB.remotes

# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc remoteToLocals*(xp: TxPoolRef; signer: EthAddress): int
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  xp.txCallBackOrDBExclusively:
    xp.txDB.setLocal(signer)
    result = xp.txDB.bySender.eq(signer).nItems

# ------------------------------------------------------------------------------
# Public functions, per-tx-item operations
# ------------------------------------------------------------------------------

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
proc getItem*(xp: TxPoolRef; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns a transaction if it is contained in the pool.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    result = xp.txDB.byItemID.eq(hash)

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

proc disposeItems*(xp: TxPoolRef; item: TxItemRef;
                   reason = txInfoExplicitDisposal;
                   otherReason = txInfoImpliedDisposal)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move item to wastebasket. All items for the same sender with nonces
  ## greater than the current one are deleted, as well.
  ##
  ## It is safe to be used within a `TxJobItemApply` call back function.
  xp.txCallBackOrDBExclusively:
    discard xp.txDB.dispose(item, reason)
    # delete all items with higher nonces
    let rc = xp.txDB.bySender.eq(item.sender)
    if rc.isOK:
      for other in rc.value.data.walkItems(item.tx.nonce):
        discard xp.txDB.dispose(other, otherReason)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

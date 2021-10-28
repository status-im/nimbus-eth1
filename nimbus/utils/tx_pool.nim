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
## * Currently too much fuss about locks and events, simplify to what is really
##   needed. It seems that pushing txs is the only async job which generalises
##   to adding a job to the job queue. Question: what about `jobCommit()`?
## * Packing blocks:
##   + Incrementally update the assembled block cache (or better use a bucket?)
##   + Current packing cycle results to one tx/address. Check whether it makes
##     sense to sort of bundle all txs/address.
## * There is no need for `txJobEvictionInactive` as expired txs can be
##   deleted on the fly while processing jobs
##
## Transaction state diagram:
## --------------------------
## ::
##  .                   .                          .
##  .     <Job queue>   .   <Accounting system>    .   <Tip/waste disposal>
##  .                   .                          .
##  .                   .         +------------+   .
##  .        +------------------> | pending(1) | ------------+
##  .        |          .         +------------+   .         |
##  .        |          .            |  ^    ^     .         |
##  .        |          .            V  |    |     .         |
##  .        |          .    +-----------+   |     .         |
##  .  --> enter(0) -------> | staged(2) |   |     .         |
##  .        |          .    +-----------+   |     .         |
##  .        |          .      |     |       |     .         |
##  .        |          .      |     V       |     .         |
##  .        |          .      |   +-----------+   .         |
##  .        |          .      |   | packed(3) | ----------+ |
##  .        |          .      |   +-----------+   .       | |
##  .        |          .      |                   .       v v
##  .        |          .      |                   .   +----------------+
##  .        |          .      +---------------------> |  rejected(4)   |
##  .        +---------------------------------------> | (waste basket) |
##  .                   .                          .   +----------------+
##
## Terminology
## ----------
## There are the job *queue* and the pending, staged, and stage *buckets*
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
## * Pending transactions bucket (1):
##   + It holds txs tested all right but not ready to fit into a block
##   + These txs are stored with meta-data and marked `txItemPending`
##   + Txs have a `nonce` which is not smaller than the nonce value of the tx
##     sender account. If it is greater than the one of the tx sender account,
##     the predecessor nonce, i.e. `nonce-1` is in the database.
##
## * Staged transactions bucket (2):
##   + It holds vetted txs that are ready to go into a block.
##   + Txs are accepted against minimum fee check and other parameters (if any)
##   + Txs are marked `txItemStaged`
##   + Txs have a `nonce` equal to the current value of the tx sender account.
##   + Re-org or other events may send them to pending(1) or staged(3) bucket
##
## * Packed transactions bucket (3):
##   + All transactions are to be placed and inclusded in a block
##   + Transactions are marked `txItemPacked`
##   + Re-org or other events may send txs back to pending(1) bucket
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
##    xq.pjaUpdatePacked                  # stash task to assemble packed bucket
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
## Following, another job is added to the batch via `pjaUpdatePacked()`
## requesting to fill the *packed* bucket after the added jobs have been
## processed.
##
## In this example, not until `nextBlock()` is invoked, the batch of jobs in
## the *job queue* will be processed. This directive will implicitly call
## `jobCommit()` which invokes the job processor on the batch queue. So the
## `nextBlock()` cleans up all of the job queue and pulls as many transactions
## as possible from the *packed* bucket, packs them into the block up until it
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
## `(<status>,<reason>)` where `<status>` is a *bucket* label `pending`,
## `staged`, or `packed`, and `<reason>` is sort of an error code. An `item`
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
##   exceed this gas limit are stored into the pending bucket (waiting for the
##   next cycle.)
##
## baseFee
##   Applicable to post-London only and compiled from the current block chain
##   head. Incoming txs with smaller `maxFee` values are stored in the pending
##   bucket (waiting for the next cycle.) For practical reasons, `baseFee` is
##   zero for pre-London block chain states.
##
## minFeePrice, *optional*
##   Applies no EIP-1559 txs only. Txs are packed if `maxFee` is at least
##   that value.
##
## minTipPrice, *optional*
##   For EIP-1559, txs are packed if the expected tip (see `estimatedGasTip()`)
##   is at least that value. In compatibility mode for legacy txs, this
##   degenerates to `gasPrice - baseFee`.
##
## minPlGasPrice, *optional*
##   For pre-London or legacy txs, this parameter has precedence over
##   `minTipPrice`. Txs are packed if the `gasPrice` is at least that value.
##
## trgGasLimit, maxGasLimit
##   These parameters are derived from the current block chain head. They
##   limit how many blocks from the packed bucket can be packed into the body
##   of the new block.
##
## lifeTime
##   Older job can be purged from the system.
##
##

import
  ./keyed_queue,
  ./tx_pool/[tx_dbhead, tx_desc, tx_info, tx_item, tx_job],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tasks,
  ./tx_pool/tx_tasks/[tx_add_tx,
                      tx_adjust_head,
                      tx_packed_items,
                      tx_pack_items,
                      tx_staged_items],
  chronicles,
  eth/[common, keys],
  stew/results

# hide complexity unless really needed
when JobWaitEnabled:
  import chronos

export
  TxItemRef,
  TxItemStatus,
  TxJobDataRef,
  TxJobID,
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
  var rc = xp.byJob.fetch
  while rc.isOK:
    let task = rc.value
    rc = xp.byJob.fetch
    result.inc

    case task.data.kind
    of txJobNone:
      # No action
      discard

    of txJobAbort:
      # Stop processing and flush job queue (including the current one)
      xp.byJob.clear
      break

    of txJobAddTxs:
      # Add txs => pending(1), staged(2), or rejected(4) (see comment
      # on top of this source file for details.)
      var args = task.data.addTxsArgs
      for tx in args.txs.mitems:
        xp.addTx(tx, args.info)
      xp.dirtyStaged = true # change may affect `staged` items
      xp.dirtyPacked = true  # change may affect `packed` items

    of txJobEvictionInactive:
      # Move transactions older than `xp.lifeTime` to the waste basket.
      xp.deleteExpiredItems(xp.lifeTime)

    of txJobFlushRejects:
      # Deletes at most the `maxItems` oldest items from the waste basket.
      let args = task.data.flushRejectsArgs
      discard xp.txDB.flushRejects(args.maxItems)

    of txJobPackBlock:
      # Pack a block fetching items from the `packed` bucket. For included
      # txs, the item wrappers are moved to the waste basket.
      xp.packItemsIntoBlock

    of txJobSetHead: # FIXME: tbd
      # Change the insertion block header. This call might imply
      # re-calculating all current transaction states.
      discard

    of txJobUpdateStaged:
      # For all items `pending` and `staged` items, re-calculate the status. If
      # the `force` flag is set, re-calculation is done even though the change
      # flags remained unset.
      let args = task.data.updateStagedArgs
      if xp.dirtyStaged or args.force or xp.dirtyStaged:
        xp.stagedItemsUpdate
        xp.dirtyStaged = false  # changes commited
        xp.dirtyPacked = true    # change may affect `packed` items

    of txJobUpdatePacked:
      # For all `staged` and `packed` items, re-calculate the status.  If
      # the `force` flag is set, re-calculation is done even though the change
      # flags remained unset. If there was no change in the `minTipPrice` and
      # `minFeePrice`, only re-assign from `staged` and `packed`.
      let args = task.data.updatePackedArgs
      if args.force or xp.minFeePriceChanged or xp.minTipPriceChanged:
        xp.packedItemsReorg
        discard xp.minFeePriceChanged # reset change detect
        discard xp.minTipPriceChanged # reset change detect
        xp.dirtyPacked = false        # changes commited
        xp.dirtyStaged = true         # change may affect `staged` items
      elif xp.dirtyPacked or xp.dirtyPacked:
        xp.packedItemsAppend
        xp.dirtyPacked = false
        xp.dirtyPacked = false        # changes commited

# ------------------------------------------------------------------------------
# Public functions, task manager, pool action1 serialiser
# ------------------------------------------------------------------------------

proc nJobsWaiting*(xp: TxPoolRef): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Return the number of jobs currently unprocessed, waiting.
  xp.byJob.len

proc job*(xp: TxPoolRef; job: TxJobDataRef): TxJobID
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## Add a new job to the queue (but do not start the commit loop.)
  xp.byJob.add(job)

proc jobCommit*(xp: TxPoolRef)
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## This function processes all jobs currently on the queue.
  let nJobs = xp.processJobs
  debug "processed jobs", nJobs

# hide complexity unless really needed
when JobWaitEnabled:
  proc jobWait*(xp: TxPoolRef) {.async,raises: [Defect,CatchableError].} =
    ## Asynchronously wait until at least one job is available. This
    ## function might be useful for testing (available only if the
    ## `JobWaitEnabled` compiler flag is set.)
    await xp.byJob.waitAvail

# ------------------------------------------------------------------------------
# Public functions, immediate actions (not pending as a job.)
# ------------------------------------------------------------------------------

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
# core/tx_pool.go(1728): func (t *txLookup) Count() int {
# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
proc count*(xp: TxPoolRef): TxTabsStatsCount
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the current pool stats: the number of transactions in the
  ## database: *local*, *remote*, *staged*, *packed*, etc.
  xp.txDB.statsCount


# core/tx_pool.go(435): func (pool *TxPool) GasPrice() *big.Int {
proc getMinFeePrice*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter for `minFeePrice`, the current gas fee enforced by the transaction
  ## pool for txs to be packed. This is an EIP-1559 only parameter (see
  ## `stage1559MinFee` strategy.)
  xp.minFeePrice

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinFeePrice*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minFeePrice`. Increasing it might remove some post-London
  ## transactions when the `packed` bucket is re-built.
  xp.minFeePrice = val
  xp.dirtyPacked = false


proc getMinTipPrice*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter for `minTipPrice`, the current gas tip (or priority fee) enforced
  ## by the transaction pool. This is an EIP-1559 parameter but with a fall
  ## back legacy interpretation (see `stage1559MinTip` strategy.)
  xp.minTipPrice

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinTipPrice*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minTipPrice`. Increasing it might remove some transactions
  ## when the `packed` bucket is re-built.
  xp.minTipPrice = val
  xp.dirtyPacked = false


proc getMinPlGasPrice*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter for `minPlGasPrice`, the current gas price enforced by the
  ## transaction pool. This is a pre-London parameter (see `packedPlMinPrice`
  ## strategy.)
  xp.minPlGasPrice

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc setMinPlGasPrice*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minPlGasPrice`.  Increasing it might remove some legacy
  ## transactions when the `packed` bucket is re-built.
  xp.minPlGasPrice = val
  xp.dirtyPacked = false


proc getBaseFee*(xp: TxPoolRef): GasPrice
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Get the `baseFee` implying the price list valuation and order.
  xp.txDB.baseFee

proc setBaseFee*(xp: TxPoolRef; baseFee: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, use new base fee. Note that after changing the `baseFee`
  ## parameter, most probably a database re-org should take place (e.g.
  ## invoking the job `txJobUpdateStaged`)
  xp.txDB.baseFee = baseFee      # cached value, change implies re-org
  xp.dbHead.baseFee = baseFee    # representative value
  xp.dirtyStaged = true          # change may affect `staged` items
  xp.dirtyPacked = true          # change may affect `packed` items


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
  let cached = xp.blockCache
  result.header = cached.blockHeader
  for item in cached.blockItems:
    result.txs.add item.tx

proc fetchBlock*(xp: TxPoolRef): EthBlock
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Similar to `getBlock()`, only that it disposes of the txs included
  ## in the assembled block. Also the cache will empty afterwards.
  let cached = xp.blockCache
  xp.blockCache = TxPoolEthBlock.init
  result.header = cached.blockHeader
  for item in cached.blockItems:
    result.txs.add item.tx
    discard xp.txDB.dispose(item, txInfoPackedBlockIncluded)

proc nextBlock*(xp: TxPoolRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Assembles a new block from the `packed` bucket and returns the maximum
  ## block size retrieved by summing up `gasLimit` entries of the included
  ## txs.
  xp.packItemsIntoBlock
  xp.blockCache.blockSize

# core/tx_pool.go(218): func (pool *TxPool) reset(oldHead, newHead ...
proc setHead*(xp: TxPoolRef; newHeader: BlockHeader): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function moves the cached block chain head to a new head implied by
  ## the argument `newHeader`. On the way of moving there, txs will be added
  ## to or removed from the pool.
  ##
  ## If successful, `true` is returned and the last block in the cache is
  ## flushed and txs disposed. On error, `false` is returned which happens
  ## only if there is a problem with the current and the new head on the block
  ## chain (e.g. orphaned blocks.)
  if xp.adjustHead(newHeader).isOk:
    let cached = xp.blockCache
    for item in cached.blockItems:
      discard xp.txDB.dispose(item, txInfoPackedBlockIncluded)
    xp.blockCache = TxPoolEthBlock.init
    return true

# ------------------------------------------------------------------------------
# Public functions, more immediate actions deemed not so important yet
# ------------------------------------------------------------------------------

proc setMaxRejects*(xp: TxPoolRef; size: int)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set the size of the waste basket. This setting becomes effective with
  ## the next move of an item into the waste basket.
  xp.txDB.maxRejects = size

# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc getAccounts*(xp: TxPoolRef; local: bool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered `local` or `remote` (i.e.
  ## the have txs of that kind) destaged on request arguments.
  if local:
    result = xp.txDB.locals
  else:
    result = xp.txDB.remotes

# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc remoteToLocals*(xp: TxPoolRef; signer: EthAddress): int
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  xp.txDB.setLocal(signer)
  xp.txDB.bySender.eq(signer).nItems

# ------------------------------------------------------------------------------
# Public functions, per-tx-item operations
# ------------------------------------------------------------------------------

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
proc getItem*(xp: TxPoolRef; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns a transaction if it is contained in the pool.
  xp.txDB.byItemID.eq(hash)

proc setStatus*(xp: TxPoolRef; item: TxItemRef; status: TxItemStatus)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Change/update the status of the transaction item.
  if status != item.status:
    discard xp.txDB.reassign(item, status)
    if status == txItemStaged or status == txItemStaged:
      xp.dirtyStaged = true  # change may affect `staged` items
      xp.dirtyPacked = true  # change may affect `packed` items

proc disposeItems*(xp: TxPoolRef; item: TxItemRef;
                   reason = txInfoExplicitDisposal;
                   otherReason = txInfoImpliedDisposal)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move item to wastebasket. All items for the same sender with nonces
  ## greater than the current one are deleted, as well.
  discard xp.txDB.dispose(item, reason)
  # delete all items with higher nonces
  let rc = xp.txDB.bySender.eq(item.sender)
  if rc.isOK:
    for other in rc.value.data.walkItems(item.tx.nonce):
      discard xp.txDB.dispose(other, otherReason)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

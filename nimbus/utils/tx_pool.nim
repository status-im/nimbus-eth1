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
## * Support `local` txs (currently unsupported and ignored.) For
##   now, all txs are considered from `remote` accounts.
##
## * There is no handling of *zero gas price* transactions yet
##
## * Clarify whether there are legacy txs possible with post-London
##   chain blocks -- *yes, there are*.
##
## * Implement re-positioning the current insertion point, typically the head
##   of the block chain.
##
## * Packing blocks:
##   + Incrementally update the assembled block cache (or better use a bucket?)
##   + Current packing cycle results to one tx/address. Check whether it makes
##     sense to sort of bundle all txs/address.
##
##
## Transaction state diagram:
## --------------------------
## ::
##  .     <Batch queue>  .   <State buckets>           .    <Terminal state>
##  .                    .                             .
##  .                    .                             .    +----------+
##  .  --> txJobAddTxs -----------------------------------> |          |
##  .              |     .         +---------------+   .    | disposed |
##  .              +-------------> | txItemPending | -----> |          |
##  .                    .         +---------------+   .    |          |
##  .                    .           |  ^     ^        .    |  waste   |
##  .                    .           v  |     |        .    |  basket  |
##  .                    .  +--------------+  |        .    |          |
##  .                    .  | txItemStaged |  |        .    |          |
##  .                    .  +--------------+  |        .    |          |
##  .                    .     |     |  ^     |        .    |          |
##  .                    .     |     v  |     |        .    |          |
##  .                    .     |   +--------------+    .    |          |
##  .                    .     |   | txItemPacked | ------> |          |
##  .                    .     |   +--------------+    .    |          |
##  .                    .     +--------------------------> |          |
##  .                    .                             .    +----------+
##
## Discussion of transaction state diagram
## =======================================
## The three section *Job queue*, *State bucket*, and *Terminal state*
## represent three different accounting (or database) systems. Transactions
## are bundled with meta data which holds the full state and cached information
## like the sender account.
##
## Batch Queue
## -----------
## There is batch queue of type `TxJobRef` which collects different types of
## jobs to be run in a serialised manner. When the queue worker `jobCommit()`
## is invoked, all jobs are exeuted in *FIFO* mode until the queue is empty.
##
## New transactions are entered into the pool by adding them to the batch
## queue as a job of type `txJobAddTxs`. This job is to bundle a transaction
## with meta data and forward it as a `TxItemRef` type data item to
##
## * the `txItemPending` bucket if the transaction is valid and would not
##   supersede an existing transaction
## * the waste basket if the transaction is invalid
##
## If a valid transaction supersedes an existing one, the existing transaction
## is moved to the waste basket and the new transaction replaces the existing
## one.
##
## State buckets
## -------------
## Here, a transaction bundled with meta data of type `TxItemRef` is called an
## `item`. So, state bucket membership is encoded as
##
## * the `item.status` field indicates the particular bucket
## * the `item.reject` field is reset/unset and has value `txInfoOk`
##
## The following boundary conditions hold for the set of all transactions (or
## items) held in one of the buckets:
##
## * Let **T** be the set of transactions from all the buckets and **Q** be
##   the set of *(sender,nonce)* pairs derived from the transactions. Then
##   **T** and **Q** are isomorphic, i.e. for each pair *(sender,nonce)* from
##   **Q** there is exactly one transaction from **T**.
##
## * For each *(sender0,nonce0)* from **Q**, either *(sender0,nonce0-1)* is in
##   **Q** or *nonce0* is the current nonce as registered with the *sender
##   account* (implied by the block chain),
##
## Note that the latter boundary condition involves the *sender account* which
## depends on the current state of the block chain and the cached head (i.e.
## insertion point) where a new block is to be appended.
##
## The following notation us used to describe the sets *(sender,nonce)* pairs
## derived from the transactions of the buckets.
##
## * **Qpending** denotes the set of *(sender,nonce)* pairs for the bucket
##   labelled `txItemPending`
##
## * **Qstaged** denotes the set of *(sender,nonce)* pairs for the bucket
##   labelled `txItemStaged`
##
## * **Qpacked** denotes the set of *(sender,nonce)* pairs for the bucket
##   labelled `txItemPacked`
##
## The pending transactions bucket
## ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
## This bucket of `txItemPending` state items hold valid transactions that are
## not in any of the other buckets. All transactions -- or rather the items
## that wrap the transactions -- are promoted form here into other buckets.
##
## The staged transactions bucket
## ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
## This bucket of `txItemStaged` state items contains transactions that are
## ready to be added to a new block. These transactions are checked for
## expected reward when mined.
##
## The following boundary conditions holds:
##
## * For any *(sender0,nonce0)* pair from **Qstaged**, the pair
##   *(sender0,nonce0-1)* is not in **Qpending**.
##
## The latter condition implies that nonces per sender in the `txItemPending`
## bucket the have the higher values.
##
## The packed transactions bucket
## ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
## tbd ...
##
##
## The following boundary conditions holds:
##
## * For any *(sender0,nonce0)* pair from **Qpacked**, the pair
##   *(sender0,nonce0-1)* is not in **Qpending** and not in **Qstaged**.
##
## The latter condition implies that nonces per sender in the `txItemPending`
## and  `txItemStaged` buckets the have the higher values.
##
##
## Terminal state
## --------------
## All transactions are disposed into a waste basket *FIFO* of a defined
## maximal length. If this length is reached, the oldest item is deleted.
## The transactions in the waste basket are stored with meta of type
## `TxItemRef` is called an similar to the ones in the buckets (and
## called `item`).
##
## Any waste basket item has
##
## * the `item.reject` field has a value different from `txInfoOk`
##
## Thus it is clearly distinguishable from an active `item` in one of the
## buckets described above.
##
## The items in the waste basket are used as a cache in the case that a
## previously discarded transaction needs to re-enter the system. Recovering
## from the waste basket saves the effort of recovering the sender account
## from signature.
##
##
## =====================================================================
##
## xxxxxxxxxxx to be updated, below xxxxxxxxxxxxxxxxx
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
  std/[sequtils],
  ./keyed_queue,
  ./tx_pool/[tx_dbhead, tx_desc, tx_info, tx_item, tx_job],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tasks/[tx_add_tx,
                      tx_adjust_head,
                      tx_dispose_expired,
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

proc maintenanceProcessing(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Tasks to be done after job processing

  # Purge expired items
  const autoDispose = {algoAutoDisposeUnpacked} + {algoAutoDisposePacked}
  if 0 < (autoDispose * xp.algoSelect).card:
    # Move transactions older than `xp.lifeTime` to the waste basket.
    xp.disposeExpiredItems


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

    of txJobAddTxs:
      # Add txs => pending(1), staged(2), or rejected(4) (see comment
      # on top of this source file for details.)
      var args = task.data.addTxsArgs
      for tx in args.txs.mitems:
        xp.addTx(tx, args.info)
      xp.dirtyStaged = true # change may affect `staged` items
      xp.dirtyPacked = true  # change may affect `packed` items

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
# Public functions, task manager, pool action serialiser
# ------------------------------------------------------------------------------

proc job*(xp: TxPoolRef; job: TxJobDataRef): TxJobID
    {.discardable,inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Queue a new generic job (does not run `jobCommit()`.)
  xp.byJob.add(job)

# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc jobAddTxs*(xp: TxPoolRef; txs: openArray[Transaction]; info = ""): TxJobID
    {.discardable,inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Queues a batch of transactions jobs to be processed in due course
  ## (does not run `jobCommit()`.)
  xp.job(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    toSeq(txs),
      info:   info)))

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc jobAddTx*(xp: TxPoolRef; tx: var Transaction; info = ""): TxJobID
    {.discardable,inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `jobAddTxs()` but for a single transaction.
  xp.job(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    @[tx],
      info:   info)))

proc jobAddTx*(xp: TxPoolRef; tx: Transaction; info = ""): TxJobID
    {.discardable,inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `jobAddTxs()` but for a single transaction.
  xp.job(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    @[tx],
      info:   info)))


proc jobCommit*(xp: TxPoolRef; forceMaintenance = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function processes all jobs currently queued. If the the argument
  ## `forceMaintenance` is set `true`, mainenance processing is always run.
  ## Otherwise it is only run if there were active jobs.
  let nJobs = xp.processJobs
  if 0 < nJobs or forceMaintenance:
    xp.maintenanceProcessing
  debug "processed jobs", nJobs

proc nJobsWaiting*(xp: TxPoolRef): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Return the number of jobs currently unprocessed, waiting.
  xp.byJob.len

# hide complexity unless really needed
when JobWaitEnabled:
  proc jobWait*(xp: TxPoolRef) {.async,raises: [Defect,CatchableError].} =
    ## Asynchronously wait until at least one job is queued and available.
    ## This function might be useful for testing (available only if the
    ## `JobWaitEnabled` compile time constant is set.)
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


proc setAlgoSelector*(xp: TxPoolRef;
                      strategy: set[TxPoolAlgoSelectorFlags]) {.inline.} =
  ## Set strategy symbols for how handle items and buckets.
  xp.algoSelect = strategy

proc getAlgoSelector*(xp: TxPoolRef): set[TxPoolAlgoSelectorFlags] {.inline.} =
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

proc disposeItems*(xp: TxPoolRef; item: TxItemRef;
                   reason = txInfoExplicitDisposal;
                   otherReason = txInfoImpliedDisposal)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move item to wastebasket. All items for the same sender with nonces
  ## greater than the current one are deleted, as well.
  discard xp.txDB.dispose(item, reason)
  # also delete all items with higher nonces
  let rc = xp.txDB.bySender.eq(item.sender)
  if rc.isOK:
    for other in rc.value.data.walkItems(item.tx.nonce):
      discard xp.txDB.dispose(other, otherReason)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

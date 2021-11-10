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
## * Support `local` accounts the txs of which would be prioritised. This is
##   currently unsupported. For now, all txs are considered from `remote`
##   accounts.
##
## * There is no handling of *zero gas price* transactions yet
##
## * Clarify whether there are legacy txs possible with post-London
##   chain blocks -- *yes, there are*.
##
## * The incremental packer is not very smart, at the moment. This should be
##   improved. Some idea:
##   + Pack selected items until the total gas limit reaches the low block
##     size water mark but does not exceed the high water mark. -- *currently
##     implemented*
##   + Provide an extra optimisation algorithm to improve the situation by
##     re-packing as close as possible to the high water mark. This algorithm
##     can only replace the last nonce-sorted item per sender due to the
##     boundary condition on nonces.
##   + Also, `minGasLimit` is currently unused. The packer should always
##     try to reach that limit even without the `packItemsTryHarder` flag set.
##
## * Some table (used for testing & data analysis) might not be needed in
##   production environment:
##   + `byTipCap` (see tx_tipcap.nim), ordered by maxPriorityFee (or gasPrice
##     for legay txs). On the other hand, there is a suggestion (see geth
##     sources) that there is a by-tip range query of a group of txs for
##     discarding, or prioritise at a later stage when the txs are held
##     already in the buckets.
##
## * For recycled txs after block chain head adjustments, can we use the
##   `tx.value` rather than `tx.gasLimit * tx.gasPrice`?
##
## * Provide unit tests provoking a nonce gap error after back tracking
##   and moving the block chain head
##
## * Impose a size limit to the bucket database. Which items would be removed?
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
## one if the gas price of the transaction is at least `priceBump` per cent
## higher (see adjustable parameters, below.)
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
## items) held in the buckets:
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
## This bucket of `txItemPacked` state items is incrementally updated
## whenever there were new items added to the `txItemStaged` bucket. The
## packed transactions bucket is filled up not exceeding the `maxGasLimit`
## hard limit which is derived from current state of the block chain.
##
## The algorithms used to process the items and pack them is configurable.
## The contents of this bucket is used to build a new mining block.
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
## Interaction of components
## =========================
## The idea is that there are concurrent *async* instances feeding transactions
## into a batch queue via `jobAddTxs()`. The batch queue is then processed on
## demand not until `jobCommit()` is run. A piece of code using this pool
## architecture could look like as follows:
## ::
##    # see also unit test examples, e.g. "Block packer tests"
##    var db: BaseChainDB                    # to be initialised
##    var txs: seq[Transaction]              # to be initialised
##
##    proc mineThatBlock(blk: EthBlock)      # external function
##
##    ..
##
##    var xq = TxPoolRef.init(db)            # initialise tx-pool
##    ..
##
##    xq.jobAddTxs(txs)                      # add transactions to be held
##    ..                                     # .. on the batch queue
##
##    xq.jobCommit                           # run batch queue worker/processor
##    let newBlock = xq.ethBlock             # fetch current mining block
##
##    ..
##    mineThatBlock(newBlock) ...            # some external mining process
##    ..
##
##    let newTopHeader = db.getCanonicalHead # new head after mining
##    xp.jobDeltaTxsHead(newTopHeader)       # add transactions update jobs
##    xp.head = newTopHeader                 # adjust block insertion point
##    xp.jobCommit                           # run batch queue worker/processor
##
##
## Discussion of example
## ---------------------
## In the example, transactions are collected via `jobAddTx()` and added to
## a batch of jobs to be processed at a time when considered right. The
## processing is initiated with the `jobCommit()` directive.
##
## There is the block packer which works incrementally moving blocks considered
## apt to the `txItemPacked` labelled bucket. It is typically invoked
## implicitly by `jobCommit()` after some txs were processed. The currently
## accumulated gas limits for all the buckets can always be inspected with
## `gasTotals()`.
##
## The `ethBlock()` directive retrieves the current block for mining derived
## from the `txItemPacked` labelled bucket.
##
## Then mining takes place ...
##
## After mining, the view of the block chain as seen by the pool must be
## updated to be ready for a new mining process. In the best case, the
## canonical head is just moved to the currently mined block which would imply
## just to discard the contents of the `txItemPacked` labelled bucket. A more
## general block chain state head update would be more complex, though.
##
## In the most complex case, the newly mined block was added to some branch
## which has become an uncle to the new canonical head retrieved by
## `getCanonicalHead()`. In order to update the pool to the state one would
## have arrived if worked on the retrieved canonical head branch in the first
## place, the directive `jobDeltaTxsHead()` calculates the actions of what is
## needed to get just there from the locally cached head state of the pool.
## These actions are added by  `jobDeltaTxsHead()` to the batch queue to
## be executed when it is time.
##
## Then the locally cached block chain head is updated by setting a new
## `topHeader`. The *setter* behind this assignment also caches implied
## internal parameters as base fee, fork, etc. Only after the new chain head
## is set, the `jobCommit()` should be started to process the update actions
## (otherwise txs might be thrown out which could be used for packing.)
##
##
## Adjustable Parameters
## ---------------------
##
## flags
##   The `flags` parameter holds a set of strategy symbols for how to process
##   items and buckets.
##
##   *stageItems1559MinFee*
##     Stage tx items with `tx.maxFee` at least `minFeePrice`. Other items are
##     left or set pending. This symbol affects post-London tx items, only.
##
##   *stageItems1559MinTip*
##     Stage tx items with `tx.effectiveGasTip(baseFee)` at least
##     `minTipPrice`. Other items are considered underpriced and left or set
##     pending. This symbol affects post-London tx items, only.
##
##   *stageItemsPlMinPrice*
##     Stage tx items with `tx.gasPrice` at least `minPreLondonGasPrice`.
##     Other items are considered underpriced and left or set pending. This
##     symbol affects pre-London tx items, only.
##
##   *packItemsTrgGasLimitMax*
##     The packer may treat `trgGasLimit` as a soft limit and may pack an
##     additional block exceeding this limit as long as the resulting block
##     size does not exceed `maxMaxLimit`.
##
##   *packItemsTryHarder*
##     The packer will not stop at the first time when the `trgGasLimit`
##     block size exceeded while accumulating txs. It rather will ignore that
##     error and keep on trying for all staged blocks.
##
##   *autoUpdateBucketsDB*
##     Automatically update the state buckets after running batch jobs if the
##     `dirtyBuckets` flag is also set.
##
##   *autoActivateTxsPacker*
##     Automatically pack transactions  after running batch jobs if the
##    `stagedItems` flag is also set.
##
##   *autoZombifyUnpacked*
##     Automatically dispose *pending* or *staged* tx items that were added to
##     the state buckets database at least `lifeTime` ago.
##
##   *autoZombifyPacked*
##     Automatically dispose *packed* tx itemss that were added to
##     the state buckets database at least `lifeTime` ago.
##
##   *..there might be more strategy symbols..*
##
## head
##   Cached block chain insertion point. Typocally, this should be the the
##   same header as retrieved by the `getCanonicalHead()`.
##
## lifeTime
##   Txs that stay longer in one of the buckets will be  moved to a waste
##   basket. From there they will be eventually deleted oldest first when
##   the maximum size would be exceeded.
##
## minFeePrice
##   Applies no EIP-1559 txs only. Txs are packed if `maxFee` is at least
##   that value.
##
## minTipPrice
##   For EIP-1559, txs are packed if the expected tip (see `estimatedGasTip()`)
##   is at least that value. In compatibility mode for legacy txs, this
##   degenerates to `gasPrice - baseFee`.
##
## minPreLondonGasPrice
##   For pre-London or legacy txs, this parameter has precedence over
##   `minTipPrice`. Txs are packed if the `gasPrice` is at least that value.
##
## priceBump
##   There can be only one transaction in the database for the same `sender`
##   account and `nonce` value. When adding a transaction with the same
##   (`sender`, `nonce`) pair, the new transaction will replace the current one
##   if it has a gas price which is at least `priceBump` per cent higher.
##
##
## Read-Only Parameters
## --------------------
##
## baseFee
##   This parameter is derived from the current block chain head. The base fee
##   parameter modifies/determines the expected gain when packing a new block
##   (is set to *zero* for *pre-London* blocks.)
##
## dirtyBuckets
##   If `true`, the state buckets database is ready for re-org if the
##   `autoUpdateBucketsDB` flag is also set.
##
## gasLimit
##   Taken or derived from the current block chain head, incoming txs that
##   exceed this gas limit are stored into the pending bucket (waiting for the
##   next cycle.)
##
## maxGasLimit, minGasLimit, trgGasLimit
##   These parameters are derived from the current block chain head. The limit
##   parameters set conditions on how many blocks from the packed bucket can be
##   packed into the body of a new block.
##
## stagedItems
##   If `true`, the state buckets database is ready for packing staged items
##   if the `autoActivateTxsPacker` flag is also set.
##

import
  std/[sequtils, tables],
  ./tx_pool/[tx_chain, tx_desc, tx_info, tx_item, tx_job],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tasks/[tx_add, tx_head, tx_buckets, tx_dispose],
  chronicles,
  eth/[common, keys],
  stew/[keyed_queue, results]

# hide complexity unless really needed
when JobWaitEnabled:
  import chronos

export
  TxItemRef,
  TxItemStatus,
  TxJobDataRef,
  TxJobID,
  TxJobKind,
  TxPoolFlags,
  TxPoolRef,
  TxTabsGasTotals,
  TxTabsItemsCount,
  results,
  tx_desc.init,
  tx_desc.startDate,
  tx_info,
  tx_item.GasPrice,
  tx_item.`<=`,
  tx_item.`<`,
  tx_item.effectiveGasTip,
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
  if autoZombifyUnpacked in xp.pFlags or
     autoZombifyPacked in xp.pFlags:
    # Move transactions older than `xp.lifeTime` to the waste basket.
    xp.disposeExpiredItems

  # Update buckets
  if autoUpdateBucketsDB in xp.pFlags:
    if xp.pDirtyBuckets:
      # For all items, re-calculate item status values (aka bucket labels).
      # If the `force` flag is set, re-calculation is done even though the
      # change flag hes remained unset.
      if xp.bucketsUpdateAll:
        xp.pStagedItems = true # triggers packer
      xp.pDirtyBuckets = false

  # Pack txs
  if autoActivateTxsPacker in xp.pFlags:
    if xp.pStagedItems:
      # Incrementally pack txs by appropriate fetching by items from
      # the `staged` bucket.
      xp.bucketsUpdatePacked
      xp.pStagedItems = false


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
      # Add a batch of txs to the database
      var args = task.data.addTxsArgs
      let (stagedFlag,topItems) = xp.addTxs(args.txs, args.info)
      if stagedFlag:
        xp.pStagedItems = true # triggers packer
      xp.pDoubleCheckAdd topItems

    of txJobDelItemIDs:
      # Dispose a batch of items
      var args = task.data.delItemIDsArgs
      for itemID in args.itemIDs:
        let rcItem = xp.txDB.byItemID.eq(itemID)
        if rcItem.isOK:
          discard xp.txDB.dispose(rcItem.value, reason = args.reason)

# ------------------------------------------------------------------------------
# Public functions, task manager, pool actions serialiser
# ------------------------------------------------------------------------------

proc job*(xp: TxPoolRef; job: TxJobDataRef): TxJobID
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## Queue a new generic job (does not run `jobCommit()`.)
  xp.byJob.add(job)

# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc jobAddTxs*(xp: TxPoolRef; txs: openArray[Transaction]; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Queues a batch of transactions jobs to be processed in due course (does
  ## not run `jobCommit()`.)
  ##
  ## The argument Transactions `txs` may come in any order, they will be
  ## sorted by `<account,nonce>` before adding to the database with the
  ## least nonce first. For this reason, it is suggested to pass transactions
  ## in larger groups. Calling single transaction jobs, they must strictly be
  ## passed smaller nonce before larger nonce.
  discard xp.job(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    toSeq(txs),
      info:   info)))

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc jobAddTx*(xp: TxPoolRef; tx: Transaction; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `jobAddTxs()` for a single transaction.
  xp.jobAddTxs(@[tx], info)


proc jobDeltaTxsHead*(xp: TxPoolRef; newHead: BlockHeader): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function calculates the txs to add or delete that need to take place
  ## after the cached block chain head is set to the position implied by the
  ## argument `newHead`. If successful, the txs to add or delete are queued
  ## on the job queue (run `jobCommit()` to execute) and `true` is returned.
  ## Otherwise nothing is done and `false` is returned.
  let rcDiff = xp.headDiff(newHead)
  if rcDiff.isOk:
    let changes = rcDiff.value

    # Re-inject transactions, do that via job queue
    if 0 < changes.addTxs.len:
      discard xp.job(TxJobDataRef(
        kind:       txJobAddTxs,
        addTxsArgs: (
          txs:      toSeq(changes.addTxs.nextValues),
          info:     "")))

    # Delete already *mined* transactions
    if 0 < changes.remTxs.len:
      discard xp.job(TxJobDataRef(
        kind:       txJobDelItemIDs,
        delItemIDsArgs: (
          itemIDs:  toSeq(changes.remTxs.keys),
          reason:   txInfoChainHeadUpdate)))

    return true


proc jobCommit*(xp: TxPoolRef; forceMaintenance = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function processes all jobs currently queued. If the the argument
  ## `forceMaintenance` is set `true`, mainenance processing is always run.
  ## Otherwise it is only run if there were active jobs.
  let nJobs = xp.processJobs
  if 0 < nJobs or forceMaintenance:
    xp.maintenanceProcessing
  debug "processed jobs", nJobs

proc nJobs*(xp: TxPoolRef): int
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


proc triggerReorg*(xp: TxPoolRef) =
  ## This function triggers a bucket re-org action with the next job queue
  ## maintenance-processing (see `jobCommit()`) by setting the `dirtyBuckets`
  ## parameter. This re-org action eventually happens when the
  ## `autoUpdateBucketsDB` flag is also set.
  xp.pDirtyBuckets = true

proc triggerPacker*(xp: TxPoolRef; clear = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function triggers the packer that will attempt to add more txs to the
  ## `packed` bucket with the next job queue maintenance-processing (see
  ## `jobCommit()`) by setting the `stagedItems` parameter. The packer will
  ## eventually run when the `autoActivateTxsPacker` flag is also set.
  ##
  ## If the `clear` argument is set `true`, all items from the `packed` bucket
  ## are moved to the `staged` bucket. So the packer will work on an empty
  ## `packed` bucket when eventually started.
  xp.pStagedItems = true
  if clear:
    for item in xp.txDB.byStatus.incItemList(txItemPacked):
      discard xp.txDB.reassign(item, txItemStaged)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc baseFee*(xp: TxPoolRef): GasPrice =
  ## Getter, modifies/determines the expected gain when packing
  xp.chain.baseFee

proc dirtyBuckets*(xp: TxPoolRef): bool =
  ## Getter, bucket database is ready for re-org if the `autoUpdateBucketsDB`
  ## flag is also set.
  xp.pDirtyBuckets

proc ethBlock*(xp: TxPoolRef): EthBlock
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves the block made up by the txs from the `packed` bucket.
  EthBlock(
    header: xp.chain.nextHeader(xp.txDB.byStatus.eq(txItemPacked).gasLimits),
    txs: toSeq(xp.txDB.byStatus.incItemList(txItemPacked)).mapIt(it.tx))

proc gasTotals*(xp: TxPoolRef): TxTabsGasTotals
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves the current gas limit totals per bucket.
  xp.txDB.gasTotals

proc flags*(xp: TxPoolRef): set[TxPoolFlags] =
  ## Getter, retrieves strategy symbols for how to process items and buckets.
  xp.pFlags

proc maxGasLimit*(xp: TxPoolRef): GasInt =
  ## Getter, hard size limit when packing blocks (see also `trgGasLimit`.)
  xp.chain.maxGasLimit

# core/tx_pool.go(435): func (pool *TxPool) GasPrice() *big.Int {
proc minFeePrice*(xp: TxPoolRef): GasPrice =
  ## Getter, retrieves minimum for the current gas fee enforced by the
  ## transaction pool for txs to be packed. This is an EIP-1559 only
  ## parameter (see `stage1559MinFee` strategy.)
  xp.pMinFeePrice

proc minPreLondonGasPrice*(xp: TxPoolRef): GasPrice =
  ## Getter. retrieves, the current gas price enforced by the transaction
  ## pool. This is a pre-London parameter (see `packedPlMinPrice` strategy.)
  xp.pMinPlGasPrice

proc minTipPrice*(xp: TxPoolRef): GasPrice =
  ## Getter, retrieves minimum for the current gas tip (or priority fee)
  ## enforced by the transaction pool. This is an EIP-1559 parameter but it
  ## comes with a fall back interpretation (see `stage1559MinTip` strategy.)
  ## for legacy transactions.
  xp.pMinTipPrice

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
# core/tx_pool.go(1728): func (t *txLookup) Count() int {
# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
proc nItems*(xp: TxPoolRef): TxTabsItemsCount
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves the current number of items per bucket and
  ## some totals.
  xp.txDB.nItems

proc stagedItems*(xp: TxPoolRef): bool =
  ## Getter, bucket database is ready for packing staged items if the
  ##  `autoActivateTxsPacker` flag is also set.
  xp.pStagedItems

proc head*(xp: TxPoolRef): BlockHeader =
  ## Getter, cached block chain insertion point. Typocally, this should be the
  ## the same header as retrieved by the `getCanonicalHead()` (unless in the
  ## middle of a mining update.)
  xp.chain.head

proc trgGasLimit*(xp: TxPoolRef): GasInt =
  ## Getter, soft size limit when packing blocks (might be extended to
  ## `maxGasLimit`)
  xp.chain.trgGasLimit

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `flags=`*(xp: TxPoolRef; val: set[TxPoolFlags]) =
  ## Setter, strategy symbols for how to process items and buckets.
  xp.pFlags = val

proc `maxRejects=`*(xp: TxPoolRef; val: int) =
  ## Setter, the size of the waste basket. This setting becomes effective with
  ## the next move of an item into the waste basket.
  xp.txDB.maxRejects = val

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc `minFeePrice=`*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minFeePrice`.  If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinFeePrice != val:
    xp.pMinFeePrice = val
    xp.pDirtyBuckets = true

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc `minPreLondonGasPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter for `minPlGasPrice`. If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinPlGasPrice != val:
    xp.pMinPlGasPrice = val
    xp.pDirtyBuckets = true

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc `minTipPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter for `minTipPrice`. If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinTipPrice != val:
    xp.pMinTipPrice = val
    xp.pDirtyBuckets = true

proc `head=`*(xp: TxPoolRef; val: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, cached block chain insertion point. This will also update the
  ## internally cached `baseFee` (depends on the block chain state.)
  if xp.chain.head != val:
    xp.chain.head = val
    xp.pDirtyBuckets = true
    xp.pStagedItems = true

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
                   otherReason = txInfoImpliedDisposal): int
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## Move item to wastebasket. All items for the same sender with nonces
  ## greater than the current one are deleted, as well. The function returns
  ## the number of items eventally removed.
  xp.disposeItemAndHigherNonces(item, reason, otherReason)

# ------------------------------------------------------------------------------
# Public functions, more immediate actions deemed not so important yet
# ------------------------------------------------------------------------------

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
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  xp.txDB.setLocal(signer)
  xp.txDB.bySender.eq(signer).nItems

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

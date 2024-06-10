# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## TODO:
## =====
## * No uncles are handled by this pool
##
## * Impose a size limit to the bucket database. Which items would be removed?
##
## * There is a conceivable problem with the per-account optimisation. The
##   algorithm chooses an account and does not stop packing until all txs
##   of the account are packed or the block is full. In the latter case,
##   there might be some txs left unpacked from the account which might be
##   the most lucrative ones. Should this be tackled (see also next item)?
##
## * The classifier throws out all txs with negative gas tips. This implies
##   that all subsequent txs must also be suspended for this account even
##   though these following txs might be extraordinarily profitable so that
##   packing the whole account might be woth wile. Should this be considered,
##   somehow (see also previous item)?
##
##
## Transaction Pool
## ================
##
## The transaction pool collects transactions and holds them in a database.
## This database consists of the three buckets *pending*, *staged*, and
## *packed* and a *waste basket*. These database entities are discussed in
## more detail, below.
##
## At some point, there will be some transactions in the *staged* bucket.
## Upon request, the pool will pack as many of those transactions as possible
## into to *packed* bucket which will subsequently be used to generate a
## new Ethereum block.
##
## When packing transactions from *staged* into *packed* bucked, the staged
## transactions are sorted by *sender account* and *nonce*. The *sender
## account* values are ordered by a *ranking* function (highest ranking first)
## and the *nonce* values by their natural integer order. Then, transactions
## are greedily picked from the ordered set until there are enough
## transactions in the *packed* bucket. Some boundary condition applies which
## roughly says that for a given account, all the transactions packed must
## leave no gaps between nonce values when sorted.
##
## The rank function applied to the *sender account* sorting is chosen as a
## guess for higher profitability which goes with a higher rank account.
##
##
## Rank calculator
## ---------------
## Let *tx()* denote the mapping
## ::
##   tx: (account,nonce) -> tx
##
## from an index pair *(account,nonce)* to a transaction *tx*. Also, for some
## external parameter *baseFee*, let
## ::
##   maxProfit: (tx,baseFee) -> tx.effectiveGasTip(baseFee) * tx.gasLimit
##
## be the maximal tip a single transation can achieve (where unit of the
## *effectiveGasTip()* is a *price* and *gasLimit* is a *commodity value*.).
## Then the rank function
## ::
##   rank(account) = Σ maxProfit(tx(account,ν),baseFee) / Σ tx(account,ν).gasLimit
##                   ν                                    ν
##
## is a *price* estimate of the maximal avarage tip per gas unit over all
## transactions for the given account. The nonces `ν` for the summation
## run over all transactions from the *staged* and *packed* bucket.
##
##
##
##
## Pool database:
## --------------
## ::
##    <Transactions>   .   <Status buckets>      .    <Terminal state>
##                     .                         .
##                     .                         .    +----------+
##      add() ----+---------------------------------> |          |
##                |    .        +-----------+    .    | disposed |
##                +-----------> |  pending  | ------> |          |
##                     .        +-----------+    .    |          |
##                     .          |  ^   ^       .    |  waste   |
##                     .          v  |   |       .    |  basket  |
##                     .   +----------+  |       .    |          |
##                     .   |  staged  |  |       .    |          |
##                     .   +----------+  |       .    |          |
##                     .     |    |  ^   |       .    |          |
##                     .     |    v  |   |       .    |          |
##                     .     |  +----------+     .    |          |
##                     .     |  |  packed  | -------> |          |
##                     .     |  +----------+     .    |          |
##                     .     +----------------------> |          |
##                     .                         .    +----------+
##
## The three columns *Batch queue*, *State bucket*, and *Terminal state*
## represent three different accounting (or database) systems. The pool
## database is continuosly updated while new transactions are added.
## Transactions are bundled with meta data which holds the full datanbase
## state in addition to other cached information like the sender account.
##
##
## New transactions
## ----------------
## When entering the pool, new transactions are bundled with meta data and
## appended to the batch queue. These bundles are called *items* which are
## forwarded to one of the following entites:
##
## * the *staged* bucket if the transaction is valid and match some constraints
##   on expected minimum mining fees (or a semblance of that for *non-PoW*
##   networks)
## * the *pending* bucket if the transaction is valid but is not subject to be
##   held in the *staged* bucket
## * the *waste basket* if the transaction is invalid
##
## If a valid transaction item supersedes an existing one, the existing
## item is moved to the waste basket and the new transaction replaces the
## existing one in the current bucket if the gas price of the transaction is
## at least `priceBump` per cent higher (see adjustable parameters, below.)
##
## Status buckets
## --------------
## The term *bucket* is a nickname for a set of *items* (i.e. transactions
## bundled with meta data as mentioned earlier) all labelled with the same
## `status` symbol and not marked  *waste*. In particular, bucket membership
## for an item is encoded as
##
## * the `status` field indicates the particular *bucket* membership
## * the `reject` field is reset/unset and has zero-equivalent value
##
## The following boundary conditions hold for the union of all buckets:
##
## * *Unique index:*
##    Let **T** be the union of all buckets and **Q** be the
##    set of *(sender,nonce)* pairs derived from the items of **T**. Then
##    **T** and **Q** are isomorphic, i.e. for each pair *(sender,nonce)*
##    from **Q** there is exactly one item from **T**, and vice versa.
##
## * *Consecutive nonces:*
##     For each *(sender0,nonce0)* of **Q**, either
##     *(sender0,nonce0-1)* is in  **Q** or *nonce0* is the current nonce as
##     registered with the *sender account* (implied by the block chain),
##
## The *consecutive nonces* requirement involves the *sender account*
## which depends on the current state of the block chain as represented by the
## internally cached head (i.e. insertion point where a new block is to be
## appended.)
##
## The following notation describes sets of *(sender,nonce)* pairs for
## per-bucket items. It will be used for boundary conditions similar to the
## ones above.
##
## * **Pending** denotes the set of *(sender,nonce)* pairs for the
##   *pending* bucket
##
## * **Staged** denotes the set of *(sender,nonce)* pairs for the
##   *staged* bucket
##
## * **Packed** denotes the set of *(sender,nonce)* pairs for the
##   *packed* bucket
##
## The pending bucket
## ^^^^^^^^^^^^^^^^^^
## Items in this bucket hold valid transactions that are not in any of the
## other buckets. All itmes might be promoted form here into other buckets if
## the current state of the block chain as represented by the internally cached
## head changes.
##
## The staged bucket
## ^^^^^^^^^^^^^^^^^
## Items in this bucket are ready to be added to a new block. They typycally
## imply some expected minimum reward when mined on PoW networks. Some
## boundary condition holds:
##
## * *Consecutive nonces:*
##     For any *(sender0,nonce0)* pair from **Staged**, the pair
##     *(sender0,nonce0-1)* is not in **Pending**.
##
## Considering the respective boundary condition on the union of buckets
## **T**, this condition here implies that a *staged* per sender nonce has a
## predecessor in the *staged* or *packed* bucket or is a nonce as registered
## with the *sender account*.
##
## The packed bucket
## ^^^^^^^^^^^^^^^^^
## All items from this bucket have been selected from the *staged* bucket, the
## transactions of which (i.e. unwrapped items) can go right away into a new
## ethernet block. How these items are selected was described at the beginning
## of this chapter. The following boundary conditions holds:
##
## * *Consecutive nonces:*
##     For any *(sender0,nonce0)* pair from **Packed**, the pair
##     *(sender0,nonce0-1)* is neither in **Pending**, nor in **Staged**.
##
## Considering the respective boundary condition on the union of buckets
## **T**, this condition here implies that a *packed* per-sender nonce has a
## predecessor in the very *packed* bucket or is a nonce as registered with the
## *sender account*.
##
##
## Terminal state
## --------------
## After use, items are disposed into a waste basket *FIFO* queue which has a
## maximal length. If the length is exceeded, the oldest items are deleted.
## The waste basket is used as a cache for discarded transactions that need to
## re-enter the system. Recovering from the waste basket saves the effort of
## recovering the sender account from the signature. An item is identified
## *waste* if
##
## * the `reject` field is explicitely set and has a value different
##   from a zero-equivalent.
##
## So a *waste* item is clearly distinguishable from any active one as a
## member of one of the *status buckets*.
##
##
##
## Pool coding
## ===========
## A piece of code using this pool architecture could look like as follows:
## ::
##    # see also unit test examples, e.g. "Block packer tests"
##    var db: CoreDbRef                      # to be initialised
##    var txs: seq[Transaction]              # to be initialised
##
##    proc mineThatBlock(blk: EthBlock)      # external function
##
##    ..
##
##    var xq = TxPoolRef.new(db)             # initialise tx-pool
##    ..
##
##    xq.add(txs)                            # add transactions ..
##    ..                                     # .. into the buckets
##
##    let newBlock = xq.assembleBlock        # fetch current mining block
##
##    ..
##    mineThatBlock(newBlock) ...            # external mining & signing process
##    ..
##
##    xp.smartHead(newBlock.header)          # update pool, new insertion point
##
##
## Discussion of example
## ---------------------
## In the example, transactions are processed into buckets via `add()`.
##
## The `ethBlock()` directive assembles and retrieves a new block for mining
## derived from the current pool state. It invokes the block packer which
## accumulates txs from the `pending` buscket into the `packed` bucket which
## then go into the block.
##
## Then mining and signing takes place ...
##
## After mining and signing, the view of the block chain as seen by the pool
## must be updated to be ready for a new mining process. In the best case, the
## canonical head is just moved to the currently mined block which would imply
## just to discard the contents of the *packed* bucket with some additional
## transactions from the *staged* bucket. A more general block chain state
## head update would be more complex, though.
##
## In the most complex case, the newly mined block was added to some block
## chain branch which has become an uncle to the new canonical head retrieved
## by `getCanonicalHead()`. In order to update the pool to the very state
## one would have arrived if worked on the retrieved canonical head branch
## in the first place, the directive `smartHead()` calculates the actions of
## what is needed to get just there from the locally cached head state of the
## pool. These actions are applied by `smartHead()` after the internal head
## position was moved.
##
## The *setter* behind the internal head position adjustment also caches
## updated internal parameters as base fee, state, fork, etc.
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
##   *packItemsMaxGasLimit*
##     It set, the *packer* will execute and collect additional items from
##     the `staged` bucket while accumulating `gasUsed` as long as
##     `maxGasLimit` is not exceeded. If `packItemsTryHarder` flag is also
##     set, the *packer* will not stop until at least `hwmGasLimit` is
##     reached.
##
##     Otherwise the *packer* will accumulate up until `trgGasLimit` is
##     not exceeded, and not stop until at least `lwmGasLimit` is reached
##     in case `packItemsTryHarder` is also set,
##
##   *packItemsTryHarder*
##     It set, the *packer* will *not* stop accumulaing transactions up until
##     the `lwmGasLimit` or `hwmGasLimit` is reached, depending on whether
##     the `packItemsMaxGasLimit` is set. Otherwise, accumulating stops
##     immediately before the next transaction exceeds `trgGasLimit`, or
##     `maxGasLimit` depending on `packItemsMaxGasLimit`.
##
##   *autoUpdateBucketsDB*
##     Automatically update the state buckets after running batch jobs if the
##     `dirtyBuckets` flag is also set.
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
## hwmTrgPercent
##   This parameter implies the size of `hwmGasLimit` which is calculated
##   as `max(trgGasLimit, maxGasLimit * lwmTrgPercent  / 100)`.
##
## lifeTime
##   Txs that stay longer in one of the buckets will be  moved to a waste
##   basket. From there they will be eventually deleted oldest first when
##   the maximum size would be exceeded.
##
## lwmMaxPercent
##   This parameter implies the size of `lwmGasLimit` which is calculated
##   as `max(minGasLimit, trgGasLimit * lwmTrgPercent  / 100)`.
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
##   This parameter is derived from the internally cached block chain state.
##   The base fee parameter modifies/determines the expected gain when packing
##   a new block (is set to *zero* for *pre-London* blocks.)
##
## dirtyBuckets
##   If `true`, the state buckets database is ready for re-org if the
##   `autoUpdateBucketsDB` flag is also set.
##
## gasLimit
##   Taken or derived from the current block chain head, incoming txs that
##   exceed this gas limit are stored into the *pending* bucket (maybe
##   eligible for staging at the next cycle when the internally cached block
##   chain state is updated.)
##
## head
##   Cached block chain insertion point, not necessarily the same header as
##   retrieved by the `getCanonicalHead()`. This insertion point can be
##   adjusted with the `smartHead()` function.
##
## hwmGasLimit
##   This parameter is at least `trgGasLimit` and does not exceed
##   `maxGasLimit` and can be adjusted by means of setting `hwmMaxPercent`. It
##   is used by the packer as a minimum block size if both flags
##   `packItemsTryHarder` and `packItemsMaxGasLimit` are set.
##
## lwmGasLimit
##   This parameter is at least `minGasLimit` and does not exceed
##   `trgGasLimit` and can be adjusted by means of setting `lwmTrgPercent`. It
##   is used by the packer as a minimum block size if the flag
##   `packItemsTryHarder` is set and `packItemsMaxGasLimit` is unset.
##
## maxGasLimit
##   This parameter is at least `hwmGasLimit`. It is calculated considering
##   the current state of the block chain as represented by the internally
##   cached head. This parameter is used by the *packer* as a size limit if
##   `packItemsMaxGasLimit` is set.
##
## minGasLimit
##   This parameter is calculated considering the current state of the block
##   chain as represented by the internally cached head. It can be used for
##   verifying that a generated block does not underflow minimum size.
##   Underflow can only be happen if there are not enough transaction available
##   in the pool.
##
## trgGasLimit
##   This parameter is at least `lwmGasLimit` and does not exceed
##   `maxGasLimit`. It is calculated considering the current state of the block
##   chain as represented by the internally cached head. This parameter is
##   used by the *packer* as a size limit if `packItemsMaxGasLimit` is unset.
##

import
  std/[sequtils, tables],
  ./tx_pool/[tx_chain, tx_desc, tx_info, tx_item],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tasks/[
    tx_add,
    tx_bucket,
    tx_head,
    tx_dispose,
    tx_packer,
    tx_recover],
  chronicles,
  eth/keys,
  stew/keyed_queue,
  results,
  ../common/common,
  ./casper

export
  TxItemRef,
  TxItemStatus,
  TxPoolFlags,
  TxPoolRef,
  TxTabsGasTotals,
  TxTabsItemsCount,
  results,
  tx_desc.startDate,
  tx_info,
  tx_item.GasPrice,
  tx_item.`<=`,
  tx_item.`<`,
  tx_item.effectiveGasTip,
  tx_item.info,
  tx_item.itemID,
  tx_item.sender,
  tx_item.status,
  tx_item.timeStamp,
  tx_item.tx,
  tx_tabs.local,
  tx_tabs.remote

{.push raises: [].}

logScope:
  topics = "tx-pool"

# ------------------------------------------------------------------------------
# Private functions: tasks processor
# ------------------------------------------------------------------------------

proc maintenanceProcessing(xp: TxPoolRef)
    {.gcsafe,raises: [CatchableError].} =
  ## Tasks to be done after add/del txs processing

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
      # change flag has remained unset.
      discard xp.bucketUpdateAll
      xp.pDirtyBuckets = false

proc setHead(xp: TxPoolRef; val: BlockHeader)
    {.gcsafe,raises: [CatchableError].} =
  ## Update cached block chain insertion point. This will also update the
  ## internally cached `baseFee` (depends on the block chain state.)
  if xp.chain.head != val:
    xp.chain.head = val # calculates the new baseFee
    xp.txDB.baseFee = xp.chain.baseFee
    xp.pDirtyBuckets = true
    xp.bucketFlushPacked

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(T: type TxPoolRef; com: CommonRef): T
    {.gcsafe,raises: [CatchableError].} =
  ## Constructor, returns a new tx-pool descriptor.
  new result
  result.init(com)

# ------------------------------------------------------------------------------
# Public functions, task manager, pool actions serialiser
# ------------------------------------------------------------------------------

# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc add*(xp: TxPoolRef; txs: openArray[PooledTransaction]; info = "")
    {.gcsafe,raises: [CatchableError].} =
  ## Add a list of transactions to be processed and added to the buckets
  ## database. It is OK pass an empty list in which case some maintenance
  ## check can be forced.
  ##
  ## The argument Transactions `txs` may come in any order, they will be
  ## sorted by `<account,nonce>` before adding to the database with the
  ## least nonce first. For this reason, it is suggested to pass transactions
  ## in larger groups. Calling single transaction jobs, they must strictly be
  ## passed *smaller nonce* before *larger nonce*.
  xp.pDoubleCheckAdd xp.addTxs(txs, info).topItems
  xp.maintenanceProcessing

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc add*(xp: TxPoolRef; tx: PooledTransaction; info = "")
    {.gcsafe,raises: [CatchableError].} =
  ## Variant of `add()` for a single transaction.
  xp.add(@[tx], info)

proc smartHead*(xp: TxPoolRef; pos: BlockHeader; blindMode = false): bool
    {.gcsafe,raises: [CatchableError].} =
  ## This function moves the internal head cache (i.e. tx insertion point,
  ## vmState) and ponts it to a now block on the chain.
  ##
  ## In standard mode when argument `blindMode` is `false`, it calculates the
  ## txs that need to be added or deleted after moving the insertion point
  ## head so that the tx-pool will not fail to re-insert quered txs that are
  ## on the chain, already. Neither will it loose any txs. After updating the
  ## the internal head cache, the previously calculated actions will be
  ## applied.
  ##
  ## If the argument `blindMode` is passed `true`, the insertion head is
  ## simply set ignoring all changes. This mode makes sense only in very
  ## particular circumstances.
  if blindMode:
    xp.setHead(pos)
    return true

  let rcDiff = xp.headDiff(pos)
  if rcDiff.isOk:
    let changes = rcDiff.value

    # Need to move head before adding txs which may rightly be rejected in
    # `addTxs()` otherwise.
    xp.setHead(pos)

    # Re-inject transactions, do that via job queue
    if 0 < changes.addTxs.len:
      debug "queuing delta txs",
        mode = "inject",
        num = changes.addTxs.len
      xp.pDoubleCheckAdd xp.addTxs(toSeq(changes.addTxs.nextValues)).topItems

    # Delete already *mined* transactions
    if 0 < changes.remTxs.len:
      debug "queuing delta txs",
        mode = "remove",
        num = changes.remTxs.len
      xp.disposeById(toSeq(changes.remTxs.keys), txInfoChainHeadUpdate)

    xp.maintenanceProcessing
    return true

proc triggerReorg*(xp: TxPoolRef)
    {.gcsafe,raises: [CatchableError].} =
  ## This function triggers a tentative bucket re-org action by setting the
  ## `dirtyBuckets` parameter. This re-org action eventually happens only if
  ## the `autoUpdateBucketsDB` flag is also set.
  xp.pDirtyBuckets = true
  xp.maintenanceProcessing

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func com*(xp: TxPoolRef): CommonRef =
  ## Getter
  xp.chain.com

func baseFee*(xp: TxPoolRef): GasPrice =
  ## Getter, this parameter modifies/determines the expected gain when packing
  xp.chain.baseFee

func dirtyBuckets*(xp: TxPoolRef): bool =
  ## Getter, bucket database is ready for re-org if the `autoUpdateBucketsDB`
  ## flag is also set.
  xp.pDirtyBuckets

type EthBlockAndBlobsBundle* = object
  blk*: EthBlock
  blobsBundle*: Opt[BlobsBundle]

proc assembleBlock*(
    xp: TxPoolRef,
    someBaseFee: bool = false
): Result[EthBlockAndBlobsBundle, string] {.gcsafe,raises: [CatchableError].} =
  ## Getter, retrieves a packed block ready for mining and signing depending
  ## on the internally cached block chain head, the txs in the pool and some
  ## tuning parameters. The following block header fields are left
  ## uninitialised:
  ##
  ## * *extraData*: Blob
  ## * *mixHash*: Hash256
  ## * *nonce*:     BlockNonce
  ##
  ## Note that this getter runs *ad hoc* all the txs through the VM in
  ## order to build the block.

  xp.packerVmExec().isOkOr:                  # updates vmState
    return err(error)

  var blk = EthBlock(
    header: xp.chain.getHeader               # uses updated vmState
  )
  var blobsBundle: BlobsBundle

  for _, nonceList in xp.txDB.packingOrderAccounts(txItemPacked):
    for item in nonceList.incNonce:
      let tx = item.pooledTx
      blk.txs.add tx.tx
      if tx.networkPayload != nil:
        for k in tx.networkPayload.commitments:
          blobsBundle.commitments.add k
        for p in tx.networkPayload.proofs:
          blobsBundle.proofs.add p
        for blob in tx.networkPayload.blobs:
          blobsBundle.blobs.add blob

  let com = xp.chain.com
  if com.forkGTE(Shanghai):
    blk.withdrawals = Opt.some(com.pos.withdrawals)

  if not com.forkGTE(Cancun) and blobsBundle.commitments.len > 0:
    return err("PooledTransaction contains blobs prior to Cancun")
  let blobsBundleOpt =
    if com.forkGTE(Cancun):
      doAssert blobsBundle.commitments.len == blobsBundle.blobs.len
      doAssert blobsBundle.proofs.len == blobsBundle.blobs.len
      Opt.some blobsBundle
    else:
      Opt.none BlobsBundle

  if someBaseFee:
    # make sure baseFee always has something
    blk.header.baseFeePerGas = Opt.some(blk.header.baseFeePerGas.get(0.u256))

  ok EthBlockAndBlobsBundle(
    blk: blk,
    blobsBundle: blobsBundleOpt)

func gasCumulative*(xp: TxPoolRef): GasInt =
  ## Getter, retrieves the gas that will be burned in the block after
  ## retrieving it via `ethBlock`.
  xp.chain.gasUsed

func gasTotals*(xp: TxPoolRef): TxTabsGasTotals =
  ## Getter, retrieves the current gas limit totals per bucket.
  xp.txDB.gasTotals

func lwmTrgPercent*(xp: TxPoolRef): int =
  ## Getter, `trgGasLimit` percentage for `lwmGasLimit` which is
  ## `max(minGasLimit, trgGasLimit * lwmTrgPercent  / 100)`
  xp.chain.lhwm.lwmTrg

func flags*(xp: TxPoolRef): set[TxPoolFlags] =
  ## Getter, retrieves strategy symbols for how to process items and buckets.
  xp.pFlags

func head*(xp: TxPoolRef): BlockHeader =
  ## Getter, cached block chain insertion point. Typocally, this should be the
  ## the same header as retrieved by the `getCanonicalHead()` (unless in the
  ## middle of a mining update.)
  xp.chain.head

func hwmMaxPercent*(xp: TxPoolRef): int =
  ## Getter, `maxGasLimit` percentage for `hwmGasLimit` which is
  ## `max(trgGasLimit, maxGasLimit * hwmMaxPercent  / 100)`
  xp.chain.lhwm.hwmMax

func maxGasLimit*(xp: TxPoolRef): GasInt =
  ## Getter, hard size limit when packing blocks (see also `trgGasLimit`.)
  xp.chain.limits.maxLimit

# core/tx_pool.go(435): func (pool *TxPool) GasPrice() *big.Int {
func minFeePrice*(xp: TxPoolRef): GasPrice =
  ## Getter, retrieves minimum for the current gas fee enforced by the
  ## transaction pool for txs to be packed. This is an EIP-1559 only
  ## parameter (see `stage1559MinFee` strategy.)
  xp.pMinFeePrice

func minPreLondonGasPrice*(xp: TxPoolRef): GasPrice =
  ## Getter. retrieves, the current gas price enforced by the transaction
  ## pool. This is a pre-London parameter (see `packedPlMinPrice` strategy.)
  xp.pMinPlGasPrice

func minTipPrice*(xp: TxPoolRef): GasPrice =
  ## Getter, retrieves minimum for the current gas tip (or priority fee)
  ## enforced by the transaction pool. This is an EIP-1559 parameter but it
  ## comes with a fall back interpretation (see `stage1559MinTip` strategy.)
  ## for legacy transactions.
  xp.pMinTipPrice

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
# core/tx_pool.go(1728): func (t *txLookup) Count() int {
# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
func nItems*(xp: TxPoolRef): TxTabsItemsCount =
  ## Getter, retrieves the current number of items per bucket and
  ## some totals.
  xp.txDB.nItems

func profitability*(xp: TxPoolRef): GasPrice =
  ## Getter, a calculation of the average *price* per gas to be rewarded after
  ## packing the last block (see `ethBlock`). This *price* is only based on
  ## execution transaction in the VM without *PoW* specific rewards. The net
  ## profit (as opposed to the *PoW/PoA* specifc *reward*) can be calculated
  ## as `gasCumulative * profitability`.
  if 0 < xp.chain.gasUsed:
    (xp.chain.profit div xp.chain.gasUsed.u256).truncate(uint64).GasPrice
  else:
    0.GasPrice

func trgGasLimit*(xp: TxPoolRef): GasInt =
  ## Getter, soft size limit when packing blocks (might be extended to
  ## `maxGasLimit`)
  xp.chain.limits.trgLimit

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

func `baseFee=`*(xp: TxPoolRef; val: GasPrice) {.raises: [KeyError].} =
  ## Setter, sets `baseFee` explicitely witout triggering a packer update.
  ## Stil a database update might take place when updating account ranks.
  ##
  ## Typically, this function would *not* be called but rather the `smartHead()`
  ## update would be employed to do the job figuring out the proper value
  ## for the `baseFee`.
  xp.txDB.baseFee = val
  xp.chain.baseFee = val

func `lwmTrgPercent=`*(xp: TxPoolRef; val: int) =
  ## Setter, `val` arguments outside `0..100` are ignored
  if 0 <= val and val <= 100:
    xp.chain.lhwm = (
      lwmTrg: val,
      hwmMax: xp.chain.lhwm.hwmMax,
      gasFloor: xp.chain.lhwm.gasFloor,
      gasCeil: xp.chain.lhwm.gasCeil
    )

func `flags=`*(xp: TxPoolRef; val: set[TxPoolFlags]) =
  ## Setter, strategy symbols for how to process items and buckets.
  xp.pFlags = val

func `hwmMaxPercent=`*(xp: TxPoolRef; val: int) =
  ## Setter, `val` arguments outside `0..100` are ignored
  if 0 <= val and val <= 100:
    xp.chain.lhwm = (
      lwmTrg: xp.chain.lhwm.lwmTrg,
      hwmMax: val,
      gasFloor: xp.chain.lhwm.gasFloor,
      gasCeil: xp.chain.lhwm.gasCeil
    )

func `maxRejects=`*(xp: TxPoolRef; val: int) =
  ## Setter, the size of the waste basket. This setting becomes effective with
  ## the next move of an item into the waste basket.
  xp.txDB.maxRejects = val

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
func `minFeePrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter for `minFeePrice`.  If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinFeePrice != val:
    xp.pMinFeePrice = val
    xp.pDirtyBuckets = true

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
func `minPreLondonGasPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter for `minPlGasPrice`. If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinPlGasPrice != val:
    xp.pMinPlGasPrice = val
    xp.pDirtyBuckets = true

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
func `minTipPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter for `minTipPrice`. If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinTipPrice != val:
    xp.pMinTipPrice = val
    xp.pDirtyBuckets = true

# ------------------------------------------------------------------------------
# Public functions, per-tx-item operations
# ------------------------------------------------------------------------------

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
func getItem*(xp: TxPoolRef; hash: Hash256): Result[TxItemRef,void] =
  ## Returns a transaction if it is contained in the pool.
  xp.txDB.byItemID.eq(hash)

func disposeItems*(xp: TxPoolRef; item: TxItemRef;
                   reason = txInfoExplicitDisposal;
                   otherReason = txInfoImpliedDisposal): int
    {.discardable,gcsafe,raises: [CatchableError].} =
  ## Move item to wastebasket. All items for the same sender with nonces
  ## greater than the current one are deleted, as well. The function returns
  ## the number of items eventally removed.
  xp.disposeItemAndHigherNonces(item, reason, otherReason)

iterator txHashes*(xp: TxPoolRef): Hash256 =
  for txHash in nextKeys(xp.txDB.byItemID):
    yield txHash

iterator okPairs*(xp: TxPoolRef): (Hash256, TxItemRef) =
  for x in nextPairs(xp.txDB.byItemID):
    if x.data.reject == txInfoOk:
      yield (x.key, x.data)

func numTxs*(xp: TxPoolRef): int =
  xp.txDB.byItemID.len

func disposeAll*(xp: TxPoolRef) {.raises: [CatchableError].} =
  let numTx = xp.numTxs
  var list = newSeqOfCap[TxItemRef](numTx)
  for x in nextPairs(xp.txDB.byItemID):
    list.add x.data
  for x in list:
    xp.disposeItems(x)

# ------------------------------------------------------------------------------
# Public functions, local/remote accounts
# ------------------------------------------------------------------------------

func isLocal*(xp: TxPoolRef; account: EthAddress): bool =
  ## This function returns `true` if argument `account` is tagged local.
  xp.txDB.isLocal(account)

func setLocal*(xp: TxPoolRef; account: EthAddress) =
  ## Tag argument `account` local which means that the transactions from this
  ## account -- together with all other local accounts -- will be considered
  ## first for packing.
  xp.txDB.setLocal(account)

func resLocal*(xp: TxPoolRef; account: EthAddress) =
  ## Untag argument `account` as local which means that the transactions from
  ## this account -- together with all other untagged accounts -- will be
  ## considered for packing after the locally tagged accounts.
  xp.txDB.resLocal(account)

func flushLocals*(xp: TxPoolRef) =
  ## Untag all *local* addresses on the system.
  xp.txDB.flushLocals

func accountRanks*(xp: TxPoolRef): TxTabsLocality =
  ## Returns two lists, one for local and the other for non-local accounts.
  ## Any of these lists is sorted by the highest rank first. This sorting
  ## means that the order may be out-dated after adding transactions.
  xp.txDB.locality

proc addRemote*(xp: TxPoolRef;
                tx: PooledTransaction; force = false): Result[void,TxInfo]
    {.gcsafe,raises: [CatchableError].} =
  ## Adds the argument transaction `tx` to the buckets database.
  ##
  ## If the argument `force` is set `false` and the sender account of the
  ## argument transaction is tagged local, this function returns with an error.
  ## If the argument `force` is set `true`, the sender account will be untagged,
  ## i.e. made non-local.
  ##
  ## Note: This function is rather inefficient if there are more than one
  ## txs to be added for a known account. The preferable way to do this
  ## would be to use a combination of `xp.add()` and `xp.resLocal()` in any
  ## order.
  # Create or recover new item. This will wrap the argument `tx` and cache
  # the sender account and other derived data accessible.
  let rc = xp.recoverItem(
    tx, txItemPending, "remote tx peek", acceptExisting = true)
  if rc.isErr:
    return err(rc.error)

  # Temporarily stash the item in the rubbish bin to be recovered, later
  let sender = rc.value.sender
  discard xp.txDB.dispose(rc.value, txInfoTxStashed)

  # Verify local/remote account
  if force:
    xp.txDB.resLocal(sender)
  elif xp.txDB.isLocal(sender):
    return err(txInfoTxErrorRemoteExpected)

  xp.add(tx, "remote tx")
  ok()

proc addLocal*(xp: TxPoolRef;
               tx: PooledTransaction; force = false): Result[void,TxInfo]
    {.gcsafe,raises: [CatchableError].} =
  ## Adds the argument transaction `tx` to the buckets database.
  ##
  ## If the argument `force` is set `false` and the sender account of the
  ## argument transaction is _not_ tagged local, this function returns with
  ## an error. If the argument `force` is set `true`, the sender account will
  ## be tagged local.
  ##
  ## Note: This function is rather inefficient if there are more than one
  ## txs to be added for a known account. The preferable way to do this
  ## would be to use a combination of `xp.add()` and `xp.setLocal()` in any
  ## order.
  # Create or recover new item. This will wrap the argument `tx` and cache
  # the sender account and other derived data accessible.
  let rc = xp.recoverItem(
    tx, txItemPending, "local tx peek", acceptExisting = true)
  if rc.isErr:
    return err(rc.error)

  # Temporarily stash the item in the rubbish bin to be recovered, later
  let sender = rc.value.sender
  discard xp.txDB.dispose(rc.value, txInfoTxStashed)

  # Verify local/remote account
  if force:
    xp.txDB.setLocal(sender)
  elif not xp.txDB.isLocal(sender):
    return err(txInfoTxErrorLocalExpected)

  xp.add(tx, "local tx")
  ok()

func inPoolAndOk*(xp: TxPoolRef; txHash: Hash256): bool =
  let res = xp.getItem(txHash)
  if res.isErr: return false
  res.get().reject == txInfoOk

func inPoolAndReason*(xp: TxPoolRef; txHash: Hash256): Result[void, string] =
  let res = xp.getItem(txHash)
  if res.isErr:
    # try to look in rejecteds
    let r = xp.txDB.byRejects.eq(txHash)
    if r.isErr:
      return err("cannot find tx in txpool")
    else:
      return err(r.get().rejectInfo)

  let item = res.get()
  if item.reject == txInfoOk:
    return ok()
  else:
    return err(item.rejectInfo)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

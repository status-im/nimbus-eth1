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
##   *autoUpdateBucketsDB*
##     Automatically update the state buckets after running batch jobs if the
##     `dirtyBuckets` flag is also set.
##
##   *autoZombifyUnpacked*
##     Automatically dispose *pending* or *staged* tx items that were added to
##     the state buckets database at least `lifeTime` ago.
##
## lifeTime
##   Txs that stay longer in one of the buckets will be  moved to a waste
##   basket. From there they will be eventually deleted oldest first when
##   the maximum size would be exceeded.
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
## head
##   Cached block chain insertion point, not necessarily the same header as
##   retrieved by the `getCanonicalHead()`. This insertion point can be
##   adjusted with the `smartHead()` function.


import
  std/[sequtils, tables],
  ./tx_pool/[tx_packer, tx_desc, tx_info, tx_item],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tasks/[
    tx_add,
    tx_bucket,
    tx_head,
    tx_dispose],
  chronicles,
  stew/keyed_queue,
  results,
  ../common/common,
  ./chain/forked_chain,
  ./casper

export
  TxItemRef,
  TxItemStatus,
  TxPoolFlags,
  TxPoolRef,
  TxTabsItemsCount,
  results,
  tx_desc.startDate,
  tx_info,
  tx_item.effectiveGasTip,
  tx_item.info,
  tx_item.itemID,
  tx_item.sender,
  tx_item.status,
  tx_item.timeStamp,
  tx_item.tx,
  tx_desc.head

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
  if autoZombifyUnpacked in xp.pFlags:
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

proc setHead(xp: TxPoolRef; val: Header)
    {.gcsafe,raises: [CatchableError].} =
  ## Update cached block chain insertion point. This will also update the
  ## internally cached `baseFee` (depends on the block chain state.)
  if xp.head != val:
    xp.head = val # calculates the new baseFee
    xp.txDB.baseFee = xp.baseFee
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

proc smartHead*(xp: TxPoolRef; pos: Header, chain: ForkedChainRef): bool
    {.gcsafe,raises: [CatchableError].} =
  ## This function moves the internal head cache (i.e. tx insertion point,
  ## vmState) and ponts it to a now block on the chain.
  ##
  ## it calculates the
  ## txs that need to be added or deleted after moving the insertion point
  ## head so that the tx-pool will not fail to re-insert quered txs that are
  ## on the chain, already. Neither will it loose any txs. After updating the
  ## the internal head cache, the previously calculated actions will be
  ## applied.
  ##
  let rcDiff = xp.headDiff(pos, chain)
  if rcDiff.isOk:
    let changes = rcDiff.value

    # Need to move head before adding txs which may rightly be rejected in
    # `addTxs()` otherwise.
    xp.setHead(pos)

    # Delete already *mined* transactions
    if 0 < changes.remTxs.len:
      debug "queuing delta txs",
        mode = "remove",
        num = changes.remTxs.len
      xp.disposeById(toSeq(changes.remTxs.keys), txInfoChainHeadUpdate)

    xp.maintenanceProcessing
    return true

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func com*(xp: TxPoolRef): CommonRef =
  ## Getter
  xp.vmState.com

type EthBlockAndBlobsBundle* = object
  blk*: EthBlock
  blobsBundle*: Opt[BlobsBundle]
  blockValue*: UInt256

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
  ## * *mixHash*: Hash32
  ## * *nonce*:     BlockNonce
  ##
  ## Note that this getter runs *ad hoc* all the txs through the VM in
  ## order to build the block.

  let pst = xp.packerVmExec().valueOr:       # updates vmState
    return err(error)

  var blk = EthBlock(
    header: pst.assembleHeader               # uses updated vmState
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
  blk.header.transactionsRoot = calcTxRoot(blk.txs)

  let com = xp.vmState.com
  if com.isShanghaiOrLater(blk.header.timestamp):
    blk.withdrawals = Opt.some(com.pos.withdrawals)

  if not com.isCancunOrLater(blk.header.timestamp) and blobsBundle.commitments.len > 0:
    return err("PooledTransaction contains blobs prior to Cancun")
  let blobsBundleOpt =
    if com.isCancunOrLater(blk.header.timestamp):
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
    blobsBundle: blobsBundleOpt,
    blockValue: pst.blockValue)

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
# core/tx_pool.go(1728): func (t *txLookup) Count() int {
# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
func nItems*(xp: TxPoolRef): TxTabsItemsCount =
  ## Getter, retrieves the current number of items per bucket and
  ## some totals.
  xp.txDB.nItems

# ------------------------------------------------------------------------------
# Public functions, per-tx-item operations
# ------------------------------------------------------------------------------

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
func getItem*(xp: TxPoolRef; hash: Hash32): Result[TxItemRef,void] =
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

iterator txHashes*(xp: TxPoolRef): Hash32 =
  for txHash in nextKeys(xp.txDB.byItemID):
    yield txHash

iterator okPairs*(xp: TxPoolRef): (Hash32, TxItemRef) =
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

func inPoolAndOk*(xp: TxPoolRef; txHash: Hash32): bool =
  let res = xp.getItem(txHash)
  if res.isErr: return false
  res.get().reject == txInfoOk

func inPoolAndReason*(xp: TxPoolRef; txHash: Hash32): Result[void, string] =
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

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Descriptor
## ===========================
##

import
  std/[times],
  ../../db/db_chain,
  ./tx_dbhead,
  ./tx_info,
  ./tx_item,
  ./tx_job,
  ./tx_tabs,
  chronos,
  eth/[common, keys]

type
  TxPoolCallBackRecursion* = object of Defect
    ## Attempt to recurse a call back function

  TxPoolAlgoSelectorFlags* = enum ##\
    ## Algorithm strategy selector symbols for staging transactions

    algoStaged1559MinFee ##\
      ## Include tx items which have at least this `maxFee`, other items
      ## are considered underpriced.
      ##
      ## This is post-London only strategy only applicable to post-London
      ## transactions.

    algoStaged1559MinTip ##\
      ## Include tx items which have a tip at least this `estimatedGasTip`.
      ##
      ## This is post-London effecticve strategy with some legacy fall
      ## back mode (see implementation of `estimatedGasTip`.)

    algoStagedPlMinPrice ##\
      ## Tx items are included where the gas proce is at least this `gasPrice`,
      ## other items are considered underpriced.
      ##
      ## This is a legacy pre-London strategy to apply instead of
      ## `stage1559MinTip`.

    # -----------

    algoPackTrgGasLimitMax ##\
      ## When packing, do not exceed `xp.dbHead.trgGasLimit`, otherwise another
      ## block exceeding the `xp.dbHead.trgGasLimit` is accepted if it stays
      ## within the `xp.dbHead.trgMaxLimit`

    algoPackTryHarder ##\
      ## When packing, do not stop at the first failure to add another block,
      ## rather ignore that error and keep on trying for all blocks


  TxPoolEthBlock* = tuple      ## Sub-entry for `TxPoolSyncParam`
    blockHeader: BlockHeader   ## Cached header for new block
    blockItems: seq[TxItemRef] ## List opf transactions for new block
    blockSize: GasInt          ## Summed up `gasLimit` entries of `blockItems[]`

  TxPoolPrice = tuple          ## Sub-entry for `TxPoolSyncParam`
    curPrice: GasPrice         ## Value to hold and track
    prvPrice: GasPrice         ## Previous value for derecting changes

  TxPoolSyncParam* = tuple     ## Synchronised access to these parameters
    minFee: TxPoolPrice        ## Gas price enforced by the pool, `gasFeeCap`
    minTip: TxPoolPrice        ## Desired tip-per-tx target, `estimatedGasTip`
    minPlGas: TxPoolPrice      ## Desired pre-London min `gasPrice`
    blockCache: TxPoolEthBlock ## Cached header for new block

    commitLoop: bool           ## Sentinel, set while commit loop is running
    dirtyPending: bool         ## Pending bucket needs update
    dirtyStaged: bool          ## Stage bucket needs update

    algoSelect: set[TxPoolAlgoSelectorFlags] ## Packer strategy symbols


  TxPoolRef* = ref object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time           ## Start date (read-only)
    dbHead: TxDbHeadRef       ## block chain state
    lifeTime*: times.Duration ## Maximum life time of a tx in the system
    priceBump*: uint          ## Min precentage price when superseding

    byJob: TxJobRef           ## Job batch list
    byJobSync: AsyncLock      ## Serialise access to `byJob`

    txDB: TxTabsRef           ## Transaction lists & tables
    txDBSync: AsyncLock       ## Serialise access to `txDB`

    param: TxPoolSyncParam
    paramSync: AsyncLock      ## Serialise access to flags and parameters

    # locals: seq[EthAddress] ## Addresses treated as local by default
    # noLocals: bool          ## May disable handling of locals
    # priceLimit: GasPrice    ## Min gas price for acceptance into the pool
    # priceBump: GasPrice     ## Min price bump percentage to replace an already
    #                         ## existing transaction (nonce)

const
  txPoolLifeTime = ##\
    ## Maximum amount of time non-executable transaction are queued,
    ## default as set in core/tx_pool.go(184)
    initDuration(hours = 3)

  txPriceBump = ##\
    ## Minimum price bump percentage to replace an already existing
    ## transaction (nonce), default as set in core/tx_pool.go(177)
    10u

  txMinFeePrice = 1.GasPrice
  txMinTipPrice = 1.GasPrice
  txPoolAlgoStrategy = {algoStaged1559MinTip,
                         algoStaged1559MinFee,
                         algoStagedPlMinPrice}

  # Journal:   "transactions.rlp",
  # Rejournal: time.Hour,
  # PriceBump:  10,

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc init(xp: TxPoolRef; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.startDate = getTime().utc.toTime
  xp.dbHead = TxDbHeadRef.init(db)
  xp.lifeTime = txPoolLifeTime
  xp.priceBump = txPriceBump

  xp.txDB = TxTabsRef.init(xp.dbHead.baseFee)
  xp.txDBSync = newAsyncLock()

  xp.byJob = TxJobRef.init
  xp.byJobSync = newAsyncLock()

  xp.param.reset
  xp.param.minFee.curPrice = txMinFeePrice
  xp.param.minTip.curPrice = txMinTipPrice
  xp.param.algoSelect = txPoolAlgoStrategy
  xp.paramSync = newAsyncLock()

# ------------------------------------------------------------------------------
# Private functions, semaphore/locks
# ------------------------------------------------------------------------------

proc paramLock(xp: TxPoolRef) {.inline, raises: [Defect,CatchableError].} =
  ## Lock descriptor. This function should only be used implicitely by
  ## template `paramExclusively()`
  waitFor xp.paramSync.acquire

proc paramUnLock(xp: TxPoolRef) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor. This function should only be used implicitely by
  ## template `paramExclusively()`
  xp.paramSync.release

template paramExclusively(xp: TxPoolRef; action: untyped) =
  ## Handy helperused to serialise access to various flags inside the `xp`
  ## descriptor object.
  xp.paramLock
  try:
    action
  finally:
    xp.paramUnLock

# ------------------------------------------------------------------------------
# Private functions, generic getter/setter
# ------------------------------------------------------------------------------

proc getPoolPrice(xp: TxPoolRef; param: var TxPoolPrice): GasPrice
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Generic getter
  xp.paramExclusively:
    result = param.curPrice

proc setPoolPrice(xp: TxPoolRef; param: var TxPoolPrice; val: GasPrice)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Generic setter
  xp.paramExclusively:
    if param.curPrice != val:
      param.prvPrice = param.curPrice
      param.curPrice = val

proc poolPriceChanged(xp: TxPoolRef; param: var TxPoolPrice): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns `true` if there was a change, and resets the change detector.
  xp.paramExclusively:
    if param.prvPrice != param.curPrice:
      param.prvPrice = param.curPrice
      result = true

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxPoolRef; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  new result
  result.init(db)

# ------------------------------------------------------------------------------
# Public functions, semaphore/locks
# ------------------------------------------------------------------------------

proc byJobLock*(xp: TxPoolRef) {.inline, raises: [Defect,CatchableError].} =
  ## Lock sub-descriptor. This function should only be used implicitely by
  ## template `byJobExclusively()`
  waitFor xp.byJobSync.acquire

proc byJobUnLock*(xp: TxPoolRef) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock sub-descriptor. This function should only be used implicitely by
  ## template `byJobExclusively()`
  xp.byJobSync.release

template byJobExclusively*(xp: TxPoolRef; action: untyped) =
  ## Handy helper used to serialise access to `xp.byJob` sub-descriptor
  xp.byJobLock
  try:
    action
  finally:
    xp.byJobUnLock

# -----------------------------

proc txDBLock*(xp: TxPoolRef) {.inline, raises: [Defect,CatchableError].} =
  ## Lock sub-descriptor. This function should only be used implicitely by
  ## template `txDBExclusively()`
  waitFor xp.txDBSync.acquire

proc txDBUnLock*(xp: TxPoolRef) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor. This function should only be used implicitely by
  ## template `txDBExclusively()`
  xp.txDBSync.release

template txDBExclusively*(xp: TxPoolRef; action: untyped) =
  ## Handy helper used to serialise access to `xp.txDB` sub-descriptor
  xp.txDBLock
  try:
    action
  finally:
    xp.txDBUnLock

# ------------------------------------------------------------------------------
# Public functions, synchonised getters/setters
# ------------------------------------------------------------------------------

proc uniqueAccessCommitLoop*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Gain unique access, activate
  xp.paramExclusively:
    result = not xp.param.commitLoop
    xp.param.commitLoop = true

proc releaseAccessCommitLoop*(xp: TxPoolRef)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Gain unique access, unset
  xp.paramExclusively:
    xp.param.commitLoop = false

# -----------------------------

proc blockCache*(xp: TxPoolRef): TxPoolEthBlock
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, cached pieces of a block
  xp.paramExclusively:
    result = xp.param.blockCache

proc `blockCache=`*(xp: TxPoolRef; val: TxPoolEthBlock)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter
  xp.paramExclusively:
    xp.param.blockCache = val

proc blockCacheReset*(xp: TxPoolRef)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Re-setter
  xp.paramExclusively:
    xp.param.blockCache.reset

# -----------------------------

proc dirtyPending*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, `pending` bucket needs update
  xp.paramExclusively:
    result = xp.param.dirtyPending

proc `dirtyPending=`*(xp: TxPoolRef; val: bool)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter
  xp.paramExclusively:
    xp.param.dirtyPending = val

# -----------------------------

proc dirtyStaged*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, `staged` bucket needs update
  xp.paramExclusively:
    result = xp.param.dirtyStaged

proc `dirtyStaged=`*(xp: TxPoolRef; val: bool)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter
  xp.paramExclusively:
    xp.param.dirtyStaged = val

# -----------------------------

proc minFeePrice*(xp: TxPoolRef): GasPrice
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, synchronised access
  xp.getPoolPrice(xp.param.minFee)

proc `minFeePrice=`*(xp: TxPoolRef; val: GasPrice)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, synchronised access
  xp.setPoolPrice(xp.param.minFee,val)

proc minFeePriceChanged*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns `true` if there was a `nimFeePrice` change and resets
  ## the change detection.
  xp.poolPriceChanged(xp.param.minFee)

# -----------------------------

proc minTipPrice*(xp: TxPoolRef): GasPrice
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, synchronised access
  xp.getPoolPrice(xp.param.minTip)

proc `minTipPrice=`*(xp: TxPoolRef; val: GasPrice)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, synchronised access
  xp.setPoolPrice(xp.param.minTip,val)

proc minTipPriceChanged*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns `true` if there was a `nimTipPrice` change and resets
  ## the change detection.
  xp.poolPriceChanged(xp.param.minTip)

# -----------------------------

proc minPlGasPrice*(xp: TxPoolRef): GasPrice
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, synchronised access
  xp.getPoolPrice(xp.param.minPlGas)

proc `minPlGasPrice=`*(xp: TxPoolRef; val: GasPrice)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, synchronised access
  xp.setPoolPrice(xp.param.minPlGas,val)

proc minPlGasPriceChanged*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns `true` if there was a `nimTipPrice` change and resets
  ## the change detection.
  xp.poolPriceChanged(xp.param.minPlGas)

# -----------------------------

proc algoSelect*(xp: TxPoolRef): set[TxPoolAlgoSelectorFlags]
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns the set of algorithm strategy symbols for labelling items
  ## as`staged`
  xp.paramExclusively:
    result = xp.param.algoSelect

proc `algoSelect=`*(xp: TxPoolRef; val: set[TxPoolAlgoSelectorFlags])
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Install a set of algorithm strategy symbols for labelling items as`staged`
  xp.paramExclusively:
    xp.param.algoSelect = val

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc startDate*(xp: TxPoolRef): Time {.inline.} =
  ## Getter
  xp.startDate

proc txDB*(xp: TxPoolRef): TxTabsRef {.inline.} =
  ## Getter, pool database
  xp.txDB

proc byJob*(xp: TxPoolRef): TxJobRef {.inline.} =
  ## Getter, job queue
  xp.byJob

proc dbHead*(xp: TxPoolRef): TxDbHeadRef {.inline.} =
  ## Getter, block chain DB
  xp.dbHead

# ------------------------------------------------------------------------------
# Public functions, heplers (debugging only)
# ------------------------------------------------------------------------------

proc verify*(xp: TxPoolRef): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.

  block:
    let rc = xp.byJob.verify
    if rc.isErr:
      return rc
  block:
    let rc = xp.txDB.verify
    if rc.isErr:
      return rc

  # verify consecutive nonces per sender
  var
    initOk = false
    lastSender: EthAddress
    lastNonce: AccountNonce
  for item in xp.txDB.bySender.walkItems:
    if not initOk or lastSender != item.sender:
      initOk = true
      lastSender = item.sender
      lastNonce = item.tx.nonce
    elif lastNonce + 1 == item.tx.nonce:
      lastNonce = item.tx.nonce
    else:
      return err(txInfoVfyNonceChain)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

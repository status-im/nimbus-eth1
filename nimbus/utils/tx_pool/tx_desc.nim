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

  TxPoolStageSelector* = enum ##\
    ## Strategy selector symbols for staging transactions

    stageMinTip ##\
      ## Include tx items which have a tip at least this `estimatedGasTip`

    stageMinFee ##\
      ## Include tx items which have at least this `gasFeeCap`, other
      ## items are considered underpriced.


  TxPoolSyncParam* = tuple    ## Synchronised access to these parameters
    minFeePrice: GasPrice     ## Gas price enforced by the pool, `gasFeeCap`
    prvFeePrice: GasPrice     ## Previous `minFeePrice` for detecting changes

    minTipPrice: GasPrice     ## Desired tip-per-tx target, `estimatedGasTip`
    prvTipPrice: GasPrice     ## Previous `minTipPrice` for detecting changes

    commitLoop: bool          ## Sentinel, set while commit loop is running
    dirtyPending: bool        ## Pending queue needs update
    dirtyStaged: bool         ## Stage queue needs update
    isCallBack: bool          ## set if a call back is currently activated

    stageSelect: set[TxPoolStageSelector] ## Packer strategy symbols


  TxPoolRef* = ref object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time           ## Start date (read-only)
    dbHead: TxDbHeadRef       ## block chain state
    lifeTime*: times.Duration ## Maximum fife time of a queued tx

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
  txPoolLifeTime = initDuration(hours = 3)
  txMinFeePrice = 1.GasPrice
  txPoolStageStrategy = {stageMinTip, stageMinFee}

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
  xp.startDate = now().utc.toTime
  xp.dbHead = init(type TxDbHeadRef, db)
  xp.lifeTime = txPoolLifeTime

  xp.txDB = init(type TxTabsRef, xp.dbHead.baseFee)
  xp.txDBSync = newAsyncLock()

  xp.byJob = init(type TxJobRef)
  xp.byJobSync = newAsyncLock()

  xp.param.reset
  xp.param.minFeePrice = txMinFeePrice
  xp.param.stageSelect = txPoolStageStrategy
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
  action
  xp.paramUnLock

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
  action
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
  action
  xp.txDBUnLock

# -----------------------------

proc txRunCallBackSync*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ##Returns the value of the `isCallBack`
  xp.paramExclusively:
    result = xp.param.isCallBack

proc txRunCallBackSync*(xp: TxPoolRef; val: bool): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Sets the `isCallBack` parameter and returns the previous value
  xp.paramExclusively:
    result = xp.param.isCallBack
    xp.param.isCallBack = val

template txRunCallBack*(xp: TxPoolRef; action: untyped) =
  ## Handy helper for wrapping a call back. This template will raise a
  ## `TxPoolCallBackRecursion` exception on anu apttempt to recursively
  ## re-invoke this directive.
  if xp.txRunCallBackSync(true) != false:
    raise newException(TxPoolCallBackRecursion, "Call back already active")
  action
  if xp.txRunCallBackSync(false) != true:
    raise newException(TxPoolCallBackRecursion, "Lost call back semaphore")

template txCallBackOrDBExclusively*(xp: TxPoolRef; action: untyped) =
  ## Returns `true` if the `isCallBack` parameter is set
  var isCallBack = xp.txRunCallBackSync
  if not isCallBack:
    xp.txDBLock
  action
  if not isCallBack:
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

proc dirtyPending*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, pending queue needs update
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
  ## Getter, pending queue needs update
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
  xp.paramExclusively:
    result = xp.param.minFeePrice

proc `minFeePrice=`*(xp: TxPoolRef; val: GasPrice)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, synchronised access
  xp.paramExclusively:
    if xp.param.minFeePrice != val:
      xp.param.prvFeePrice = xp.param.minFeePrice
      xp.param.minFeePrice = val

proc minFeePriceChanged*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns `true` if there was a `nimFeePrice` change and resets
  ## the change detection.
  xp.paramExclusively:
    if xp.param.minFeePrice != xp.param.prvFeePrice:
      xp.param.prvFeePrice = xp.param.minFeePrice
      result = true

# -----------------------------

proc minTipPrice*(xp: TxPoolRef): GasPrice
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, synchronised access
  xp.paramExclusively:
    result = xp.param.minTipPrice

proc `minTipPrice=`*(xp: TxPoolRef; val: GasPrice)
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, synchronised access
  xp.paramExclusively:
    if xp.param.minTipPrice != val:
      xp.param.prvTipPrice = xp.param.minTipPrice
      xp.param.minTipPrice = val

proc minTipPriceChanged*(xp: TxPoolRef): bool
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns `true` if there was a `nimTipPrice` change and resets
  ## the change detection.
  xp.paramExclusively:
    if xp.param.minTipPrice != xp.param.prvTipPrice:
      xp.param.prvTipPrice = xp.param.minTipPrice
      result = true

# -----------------------------

proc stageSelect*(xp: TxPoolRef): set[TxPoolStageSelector]
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Returns the set of strategy symbols for labelling items as`staged`
  xp.paramExclusively:
    result = xp.param.stageSelect

proc `stageSelect=`*(xp: TxPoolRef; val: set[TxPoolStageSelector])
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Install a set of strategy symbols for labelling items as`staged`
  xp.paramExclusively:
    xp.param.stageSelect = val

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

  xp.txDB.verify

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
  ./tx_job,
  ./tx_tabs,
  chronos,
  eth/[common, keys]

const
  txPoolLifeTime = initDuration(hours = 3)
  txPriceLimit = 1

  # Journal:   "transactions.rlp",
  # Rejournal: time.Hour,
  # PriceBump:  10,

type
  TxPoolParam* = tuple
    gasPrice: uint64     ## Gas price enforced by the pool
    dirtyPending: bool   ## Pending queue needs update
    commitLoop: bool     ## Sentinel, set while commit loop is running
    jobExecRepeat: bool  ## Enable job processor (wrapping commit loop)

  TxPoolRef* = ref object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time           ## Start date (read-only)
    dbHead: TxDbHeadRef       ## block chain state
    lifeTime*: times.Duration ## Maximum fife time of a queued tx

    byJob: TxJobRef           ## Job batch list
    byJobSync: AsyncLock      ## Serialise access to `byJob`

    txDB: TxTabsRef           ## Transaction lists & tables
    txDBSync: AsyncLock       ## Serialise access to `txDB`

    param: TxPoolParam
    paramSync: AsyncLock      ## Serialise access to flags and parameters

    # locals: seq[EthAddress] ## Addresses treated as local by default
    # noLocals: bool          ## May disable handling of locals
    # priceLimit: GasInt      ## Min gas price for acceptance into the pool
    # priceBump: uint64       ## Min price bump percentage to replace an already
    #                         ## existing transaction (nonce)

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
  xp.param.gasPrice = txPriceLimit
  xp.paramSync = newAsyncLock()

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


proc paramLock*(xp: TxPoolRef) {.inline, raises: [Defect,CatchableError].} =
  ## Lock descriptor. This function should only be used implicitely by
  ## template `paramExclusively()`
  waitFor xp.paramSync.acquire

proc paramUnLock*(xp: TxPoolRef) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor. This function should only be used implicitely by
  ## template `paramExclusively()`
  xp.paramSync.release

template paramExclusively*(xp: TxPoolRef; action: untyped) =
  ## Handy helperused to serialise access to various flags inside the `xp`
  ## descriptor object.
  xp.paramLock
  action
  xp.paramUnLock

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

proc gasPrice*(xp: TxPoolRef): uint64 {.inline.} =
  ## Getter, as price enforced by the pool
  xp.param.gasPrice

proc commitLoop*(xp: TxPoolRef): bool {.inline.} =
  ## Getter, sentinel, set while commit loop is running
  xp.param.commitLoop

proc dirtyPending*(xp: TxPoolRef): bool {.inline.} =
  ## Getter, pending queue needs update
  xp.param.dirtyPending

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `gasPrice=`*(xp: TxPoolRef; val: uint64) {.inline.} =
  ## Setter,
  xp.param.gasPrice = val

proc `commitLoop=`*(xp: TxPoolRef; val: bool) {.inline.} =
  ## Setter
  xp.param.commitLoop = val

proc `dirtyPending=`*(xp: TxPoolRef; val: bool) {.inline.} =
  ## Setter
  xp.param.dirtyPending = val

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

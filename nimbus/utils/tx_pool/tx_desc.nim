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
  eth/[common, keys]

from chronos import
  AsyncLock,
  AsyncLockError,
  acquire,
  newAsyncLock,
  release,
  waitFor

const
  txPoolLifeTime = initDuration(hours = 3)
  txPriceLimit = 1

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
  TxPoolParam* = tuple
    gasPrice: uint64     ## Gas price enforced by the pool
    dirtyPending: bool   ## Pending queue needs update
    commitLoop: bool     ## Sentinel, set while commit loop is running

  TxPool* = object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time      ## Start date (read-only)
    dbHead: TxDbHead     ## block chain state
    lifeTime*: Duration  ## Maximum amount of time non-executable txs are queued

    byJob: TxJob         ## Job batch list
    byJobSync: AsyncLock ## Serialise access to `byJob`

    txDB: TxTabsRef      ## Transaction lists & tables
    txDBSync: AsyncLock  ## Serialise access to `txDB`

    param: TxPoolParam
    paramSync: AsyncLock ## Serialise access to flags and parameters

    # locals: seq[EthAddress] ## Addresses treated as local by default
    # noLocals: bool          ## May disable handling of locals
    # priceLimit: GasInt      ## Min gas price for acceptance into the pool
    # priceBump: uint64       ## Min price bump percentage to replace an already
    #                         ## existing transaction (nonce)

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: var TxPool; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.startDate = now().utc.toTime
  xp.dbHead.init(db)
  xp.lifeTime = txPoolLifeTime

  xp.txDB = init(type TxTabsRef, xp.dbHead.baseFee)
  xp.txDBSync = newAsyncLock()

  xp.byJob.init
  xp.byJobSync = newAsyncLock()

  xp.param.reset
  xp.param.gasPrice = txPriceLimit
  xp.paramSync = newAsyncLock()


proc init*(T: type TxPool; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  result.init(db)

# ------------------------------------------------------------------------------
# Public functions, semaphore/locks
# ------------------------------------------------------------------------------

proc byJobLock*(xp: var TxPool) {.inline, raises: [Defect,CatchableError].} =
  ## Lock sub-descriptor. This function should only be used implicitely by
  ## template `byJobExclusively()`
  waitFor xp.byJobSync.acquire

proc byJobUnLock*(xp: var TxPool) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock sub-descriptor. This function should only be used implicitely by
  ## template `byJobExclusively()`
  xp.byJobSync.release

template byJobExclusively*(xp: var TxPool; action: untyped) =
  ## Handy helper used to serialise access to `xp.byJob` sub-descriptor
  xp.byJobLock
  action
  xp.byJobUnLock


proc txDBLock*(xp: var TxPool) {.inline, raises: [Defect,CatchableError].} =
  ## Lock sub-descriptor. This function should only be used implicitely by
  ## template `txDBExclusively()`
  waitFor xp.txDBSync.acquire

proc txDBUnLock*(xp: var TxPool) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor. This function should only be used implicitely by
  ## template `txDBExclusively()`
  xp.txDBSync.release

template txDBExclusively*(txp: var TxPool; action: untyped) =
  ## Handy helper used to serialise access to `xp.txDB` sub-descriptor
  xp.txDBLock
  action
  xp.txDBUnLock


proc paramLock*(xp: var TxPool) {.inline, raises: [Defect,CatchableError].} =
  ## Lock descriptor. This function should only be used implicitely by
  ## template `paramExclusively()`
  waitFor xp.paramSync.acquire

proc paramUnLock*(xp: var TxPool) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor. This function should only be used implicitely by
  ## template `paramExclusively()`
  xp.paramSync.release

template paramExclusively*(xp: var TxPool; action: untyped) =
  ## Handy helperused to serialise access to various flags inside the `xp`
  ## descriptor object.
  xp.paramLock
  action
  xp.paramUnLock

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc startDate*(xp: var TxPool): Time {.inline.} =
  ## Getter
  xp.startDate

proc txDB*(xp: var TxPool): TxTabsRef {.inline.} =
  ## Getter, pool database
  xp.txDB

proc byJob*(xp: var TxPool): var TxJob {.inline.} =
  ## Getter, job queue
  xp.byJob

proc dbHead*(xp: var TxPool): var TxDbHead {.inline.} =
  ## Getter, block chain DB
  xp.dbHead

proc gasPrice*(xp: var TxPool): uint64 {.inline.} =
  ## Getter, as price enforced by the pool
  xp.param.gasPrice

proc commitLoop*(xp: var TxPool): bool {.inline.} =
  ## Getter, sentinel, set while commit loop is running
  xp.param.commitLoop

proc dirtyPending*(xp: var TxPool): bool {.inline.} =
  ## Getter, pending queue needs update
  xp.param.dirtyPending

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `gasPrice=`*(xp: var TxPool; val: uint64) {.inline.} =
  ## Setter,
  xp.param.gasPrice = val

proc `commitLoop=`*(xp: var TxPool; val: bool) {.inline.} =
  ## Setter
  xp.param.commitLoop = val

proc `dirtyPending=`*(xp: var TxPool; val: bool) {.inline.} =
  ## Setter
  xp.param.dirtyPending = val

# ------------------------------------------------------------------------------
# Public functions, heplers (debugging only)
# ------------------------------------------------------------------------------

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

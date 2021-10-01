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
  TxPool* = object of RootObj ##\
    ## Transaction pool descriptor
    dbHead: TxDbHead     ## block chain state
    startDate: Time      ## Start date (read-only)

    gasPrice: uint64     ## Gas price enforced by the pool
    lifeTime*: Duration  ## Maximum amount of time non-executable txs are queued

    byJob: TxJob         ## Job batch list
    txDB: TxTabsRef      ## Transaction lists & tables

    commitLoop: bool     ## Sentinel, set while commit loop is running
    dirtyPending: bool   ## Pending queue needs update

    # locals: seq[EthAddress] ## Addresses treated as local by default
    # noLocals: bool          ## May disable handling of locals
    # priceLimit: GasInt      ## Min gas price for acceptance into the pool
    # priceBump: uint64       ## Min price bump percentage to replace an already
    #                         ## existing transaction (nonce)

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc utcNow: Time {.inline.} =
  now().utc.toTime

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: var TxPool; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.dbHead.init(db)
  xp.txDB = init(type TxTabsRef, xp.dbHead.baseFee)
  xp.byJob.init

  xp.startDate = utcNow()
  xp.gasPrice = txPriceLimit
  xp.lifeTime = txPoolLifeTime

proc init*(T: type TxPool; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  result.init(db)

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
  xp.gasPrice

proc commitLoop*(xp: var TxPool): bool {.inline.} =
  ## Getter, sentinel, set while commit loop is running
  xp.commitLoop

proc dirtyPending*(xp: var TxPool): bool {.inline.} =
  ## Getter, pending queue needs update
  xp.dirtyPending

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `gasPrice=`*(xp: var TxPool; val: uint64) {.inline.} =
  ## Setter,
  xp.gasPrice = val

proc `commitLoop=`*(xp: var TxPool; val: bool) {.inline.} =
  ## Setter
  xp.commitLoop = val

proc `dirtyPending=`*(xp: var TxPool; val: bool) {.inline.} =
  ## Setter
  xp.dirtyPending = val

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

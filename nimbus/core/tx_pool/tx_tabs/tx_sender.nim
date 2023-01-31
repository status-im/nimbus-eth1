# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Table: `Sender` > `status` | all > `nonce`
## ===========================================================
##

import
  std/[math],
  ../tx_info,
  ../tx_item,
  eth/[common],
  stew/[results, keyed_queue, keyed_queue/kq_debug, sorted_set]

{.push raises: [].}

type
  TxSenderNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` values containing transaction\
    ## item lists.
    gasLimits: GasInt     ## Accumulated gas limits
    profit: float64       ## Aggregated `effectiveGasTip*gasLimit` values
    nonceList: SortedSet[AccountNonce,TxItemRef]

  TxSenderSchedRef* = ref object ##\
    ## For a sender, items can be accessed by *nonce*, or *status,nonce*.
    size: int             ## Total number of items
    statusList: array[TxItemStatus,TxSenderNonceRef]
    allList: TxSenderNonceRef

  TxSenderTab* = object ##\
    ## Per address table This is table provided as a keyed queue so deletion\
    ## while traversing is supported and predictable.
    size: int             ## Total number of items
    baseFee: GasPrice     ## For aggregating `effectiveGasTip` => `gasTipSum`
    addrList: KeyedQueue[EthAddress,TxSenderSchedRef]

  TxSenderSchedule* = enum ##\
    ## Generalised key for sub-list to be used in `TxSenderNoncePair`
    txSenderAny = 0       ## All entries status (aka bucket name) ...
    txSenderPending
    txSenderStaged
    txSenderPacked

  TxSenderInx = object ##\
    ## Internal access data
    schedData: TxSenderSchedRef
    statusNonce: TxSenderNonceRef       ## status items sub-list
    allNonce: TxSenderNonceRef          ## all items sub-list

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `$`(rq: TxSenderSchedRef): string =
  ## Needed by `rq.verify()` for printing error messages
  var n = 0
  for status in TxItemStatus:
    if not rq.statusList[status].isNil:
      n.inc
  $n

proc nActive(rq: TxSenderSchedRef): int =
  ## Number of non-nil items
  for status in TxItemStatus:
    if not rq.statusList[status].isNil:
      result.inc

func differs(a, b: float64): bool =
  ## Syntactic sugar, crude comparator for large integer values a and b coded
  ## as `float64`. This function is mainly provided for the `verify()` function.
  # note that later NIM compilers also provide `almostEqual()`
  const
    epsilon = 1.0e+15'f64           # just arbitrary, something small
  let
    x = max(a, b)
    y = min(a, b)
    z = if x == 0: 1'f64 else: x    # 1f64 covers the case x == y == 0.0
  epsilon < (x - y) / z


func toSenderSchedule(status: TxItemStatus): TxSenderSchedule =
  case status
  of txItemPending:
    return txSenderPending
  of txItemStaged:
    return txSenderStaged
  of txItemPacked:
    return txSenderPacked

proc getRank(schedData: TxSenderSchedRef): int64 =
  ## Rank calculator
  let pendingData = schedData.statusList[txItemPending]

  var
    maxProfit = schedData.allList.profit
    gasLimits = schedData.allList.gasLimits
  if not pendingData.isNil:
    maxProfit -= pendingData.profit
    gasLimits -= pendingData.gasLimits

  if gasLimits <= 0:
    return int64.low
  let profit = maxProfit / gasLimits.float64

  # Beware of under/overflow
  if profit < int64.low.float64:
    return int64.low
  if int64.high.float64 < profit:
    return int64.high

  profit.int64

proc maxProfit(item: TxItemRef; baseFee: GasPrice): float64 =
  ## Profit calculator
  item.tx.gasLimit.float64 * item.tx.effectiveGasTip(baseFee).float64

proc recalcProfit(nonceData: TxSenderNonceRef; baseFee: GasPrice) =
  ## Re-calculate profit value depending on `baseFee`
  nonceData.profit = 0.0
  var rc = nonceData.nonceList.ge(AccountNonce.low)
  while rc.isOk:
    let item = rc.value.data
    nonceData.profit += item.maxProfit(baseFee)
    rc = nonceData.nonceList.gt(item.tx.nonce)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc mkInxImpl(gt: var TxSenderTab; item: TxItemRef): Result[TxSenderInx,void]
    {.gcsafe,raises: [KeyError].} =
  var inxData: TxSenderInx

  if gt.addrList.hasKey(item.sender):
    inxData.schedData = gt.addrList[item.sender]
  else:
    new inxData.schedData
    gt.addrList[item.sender] = inxData.schedData

  # all items sub-list
  if inxData.schedData.allList.isNil:
    new inxData.allNonce
    inxData.allNonce.nonceList.init
    inxData.schedData.allList = inxData.allNonce
  else:
    inxData.allNonce = inxData.schedData.allList
  let rc = inxData.allNonce.nonceList.insert(item.tx.nonce)
  if rc.isErr:
    return err()
  rc.value.data = item

  # by status items sub-list
  if inxData.schedData.statusList[item.status].isNil:
    new inxData.statusNonce
    inxData.statusNonce.nonceList.init
    inxData.schedData.statusList[item.status] = inxData.statusNonce
  else:
    inxData.statusNonce = inxData.schedData.statusList[item.status]
  # this is a new item, checked at `all items sub-list` above
  inxData.statusNonce.nonceList.insert(item.tx.nonce).value.data = item

  return ok(inxData)


proc getInxImpl(gt: var TxSenderTab; item: TxItemRef): Result[TxSenderInx,void]
    {.gcsafe,raises: [KeyError].} =

  var inxData: TxSenderInx
  if not gt.addrList.hasKey(item.sender):
    return err()

  # Sub-lists are non-nil as `TxSenderSchedRef` cannot be empty
  inxData.schedData = gt.addrList[item.sender]

  # by status items sub-list
  inxData.statusNonce = inxData.schedData.statusList[item.status]

  # all items sub-list
  inxData.allNonce = inxData.schedData.allList

  ok(inxData)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(gt: var TxSenderTab) =
  ## Constructor
  gt.size = 0
  gt.addrList.init

# ------------------------------------------------------------------------------
# Public functions, base management operations
# ------------------------------------------------------------------------------

proc insert*(gt: var TxSenderTab; item: TxItemRef): bool
    {.gcsafe,raises: [KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let rc = gt.mkInxImpl(item)
  if rc.isOk:
    let
      inx = rc.value
      tip = item.maxProfit(gt.baseFee)
    gt.size.inc

    inx.schedData.size.inc

    inx.statusNonce.gasLimits += item.tx.gasLimit
    inx.statusNonce.profit += tip

    inx.allNonce.gasLimits += item.tx.gasLimit
    inx.allNonce.profit += tip
    return true


proc delete*(gt: var TxSenderTab; item: TxItemRef): bool
    {.gcsafe,raises: [KeyError].} =
  let rc = gt.getInxImpl(item)
  if rc.isOk:
    let
      inx = rc.value
      tip = item.maxProfit(gt.baseFee)
    gt.size.dec

    inx.schedData.size.dec

    discard inx.allNonce.nonceList.delete(item.tx.nonce)
    if inx.allNonce.nonceList.len == 0:
      # this was the last nonce for that sender account
      discard gt.addrList.delete(item.sender)
      return true

    inx.allNonce.gasLimits -= item.tx.gasLimit
    inx.allNonce.profit -= tip

    discard inx.statusNonce.nonceList.delete(item.tx.nonce)
    if inx.statusNonce.nonceList.len == 0:
      inx.schedData.statusList[item.status] = nil
      return true

    inx.statusNonce.gasLimits -= item.tx.gasLimit
    inx.statusNonce.profit -= tip
    return true


proc verify*(gt: var TxSenderTab): Result[void,TxInfo]
    {.gcsafe,raises: [CatchableError].} =
  ## Walk `EthAddress` > `TxSenderLocus` > `AccountNonce` > items

  block:
    let rc = gt.addrList.verify
    if rc.isErr:
      return err(txInfoVfySenderRbTree)

  var totalCount = 0
  for p in gt.addrList.nextPairs:
    let schedData = p.data
    #var addrCount = 0 -- notused
    # at least one of status lists must be available
    if schedData.nActive == 0:
      return err(txInfoVfySenderLeafEmpty)
    if schedData.allList.isNil:
      return err(txInfoVfySenderLeafEmpty)

    # status list
    # ----------------------------------------------------------------
    var
      statusCount = 0
      statusGas = 0.GasInt
      statusProfit = 0.0
    for status in TxItemStatus:
      let statusData = schedData.statusList[status]

      if not statusData.isNil:
        block:
          let rc = statusData.nonceList.verify
          if rc.isErr:
            return err(txInfoVfySenderRbTree)

        var
          rcNonce = statusData.nonceList.ge(AccountNonce.low)
          bucketProfit = 0.0
        while rcNonce.isOk:
          let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = statusData.nonceList.gt(nonceKey)

          statusGas += item.tx.gasLimit
          statusCount.inc

          bucketProfit += item.maxProfit(gt.baseFee)

        statusProfit += bucketProfit

        if differs(statusData.profit, bucketProfit):
          echo "*** verify (1) ", statusData.profit," != ", bucketProfit
          return err(txInfoVfySenderProfits)

        # verify that `recalcProfit()` works
        statusData.recalcProfit(gt.baseFee)
        if differs(statusData.profit, bucketProfit):
          echo "*** verify (2) ", statusData.profit," != ", bucketProfit
          return err(txInfoVfySenderProfits)

    # allList
    # ----------------------------------------------------------------
    var
      allCount = 0
      allGas = 0.GasInt
      allProfit = 0.0
    block:
      var allData = schedData.allList

      block:
        let rc = allData.nonceList.verify
        if rc.isErr:
          return err(txInfoVfySenderRbTree)

        var rcNonce = allData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = allData.nonceList.gt(nonceKey)

          allProfit += item.maxProfit(gt.baseFee)
          allGas += item.tx.gasLimit
          allCount.inc

        if differs(allData.profit, allProfit):
          echo "*** verify (3) ", allData.profit," != ", allProfit
          return err(txInfoVfySenderProfits)

        # verify that `recalcProfit()` works
        allData.recalcProfit(gt.baseFee)
        if differs(allData.profit, allProfit):
          echo "*** verify (4) ", allData.profit," != ", allProfit
          return err(txInfoVfySenderProfits)

    if differs(allProfit, statusProfit):
      echo "*** verify (5) ", allProfit," != ", statusProfit
      return err(txInfoVfySenderProfits)
    if allGas != statusGas:
      return err(txInfoVfySenderTotal)
    if statusCount != schedData.size:
      return err(txInfoVfySenderTotal)
    if allCount != schedData.size:
      return err(txInfoVfySenderTotal)

    totalCount += allCount

  # end while
  if totalCount != gt.size:
    return err(txInfoVfySenderTotal)

  ok()

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc baseFee*(gt: var TxSenderTab): GasPrice =
  ## Getter
  gt.baseFee

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(gt: var TxSenderTab; val: GasPrice) =
  ## Setter. When invoked, there is *always* a re-calculation of the profit
  ## values stored with the sender address.
  gt.baseFee = val

  for p in gt.addrList.nextPairs:
    let schedData = p.data

    # statusList[]
    for status in TxItemStatus:
      let statusData = schedData.statusList[status]
      if not statusData.isNil:
        statusData.recalcProfit(val)

    # allList
    schedData.allList.recalcProfit(val)

# ------------------------------------------------------------------------------
# Public SortedSet ops -- `EthAddress` (level 0)
# ------------------------------------------------------------------------------

proc len*(gt: var TxSenderTab): int =
  gt.addrList.len

proc nItems*(gt: var TxSenderTab): int =
  ## Getter, total number of items in the list
  gt.size


proc rank*(gt: var TxSenderTab; sender: EthAddress): Result[int64,void]
    {.gcsafe,raises: [KeyError].} =
  ## The *rank* of the `sender` argument address is the
  ## ::
  ##    maxProfit() / gasLimits()
  ##
  ## calculated over all items of the `staged` and `packed` buckets.
  ##
  if gt.addrList.hasKey(sender):
    return ok(gt.addrList[sender].getRank)
  err()


proc eq*(gt: var TxSenderTab; sender: EthAddress):
       SortedSetResult[EthAddress,TxSenderSchedRef]
    {.gcsafe,raises: [KeyError].} =
  if gt.addrList.hasKey(sender):
    return toSortedSetResult(key = sender, data = gt.addrList[sender])
  err(rbNotFound)

# ------------------------------------------------------------------------------
# Public array ops -- `TxSenderSchedule` (level 1)
# ------------------------------------------------------------------------------

proc len*(schedData: TxSenderSchedRef): int =
  schedData.nActive


proc nItems*(schedData: TxSenderSchedRef): int =
  ## Getter, total number of items in the sub-list
  schedData.size

proc nItems*(rc: SortedSetResult[EthAddress,TxSenderSchedRef]): int =
  if rc.isOk:
    return rc.value.data.nItems
  0


proc eq*(schedData: TxSenderSchedRef; status: TxItemStatus):
       SortedSetResult[TxSenderSchedule,TxSenderNonceRef] =
  ## Return by status sub-list
  let nonceData = schedData.statusList[status]
  if nonceData.isNil:
    return err(rbNotFound)
  toSortedSetResult(key = status.toSenderSchedule, data = nonceData)

proc eq*(rc: SortedSetResult[EthAddress,TxSenderSchedRef];
         status: TxItemStatus):
           SortedSetResult[TxSenderSchedule,TxSenderNonceRef] =
  ## Return by status sub-list
  if rc.isOk:
    return rc.value.data.eq(status)
  err(rc.error)


proc sub*(schedData: TxSenderSchedRef):
        SortedSetResult[TxSenderSchedule,TxSenderNonceRef] =
  ## Return all-entries sub-list
  let nonceData = schedData.allList
  if nonceData.isNil:
    return err(rbNotFound)
  toSortedSetResult(key = txSenderAny, data = nonceData)

proc sub*(rc: SortedSetResult[EthAddress,TxSenderSchedRef]):
        SortedSetResult[TxSenderSchedule,TxSenderNonceRef] =
  ## Return all-entries sub-list
  if rc.isOk:
    return rc.value.data.sub
  err(rc.error)


proc eq*(schedData: TxSenderSchedRef;
         key: TxSenderSchedule):
           SortedSetResult[TxSenderSchedule,TxSenderNonceRef] =
  ## Variant of `eq()` using unified key schedule
  case key
  of txSenderAny:
    return schedData.sub
  of txSenderPending:
    return schedData.eq(txItemPending)
  of txSenderStaged:
    return schedData.eq(txItemStaged)
  of txSenderPacked:
    return schedData.eq(txItemPacked)

proc eq*(rc: SortedSetResult[EthAddress,TxSenderSchedRef];
         key: TxSenderSchedule):
           SortedSetResult[TxSenderSchedule,TxSenderNonceRef] =
  if rc.isOk:
    return rc.value.data.eq(key)
  err(rc.error)

# ------------------------------------------------------------------------------
# Public SortedSet ops -- `AccountNonce` (level 2)
# ------------------------------------------------------------------------------

proc nItems*(nonceData: TxSenderNonceRef): int =
  ## Getter, total number of items in the sub-list
  nonceData.nonceList.len

proc nItems*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef]): int =
  if rc.isOk:
    return rc.value.data.nItems
  0


proc gasLimits*(nonceData: TxSenderNonceRef): GasInt =
  ## Getter, aggregated valued of `gasLimit` for all items in the
  ## argument list.
  nonceData.gasLimits

proc gasLimits*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef]):
              GasInt =
  ## Getter variant of `gasLimits()`, returns `0` if `rc.isErr`
  ## evaluates `true`.
  if rc.isOk:
    return rc.value.data.gasLimits
  0


proc maxProfit*(nonceData: TxSenderNonceRef): float64 =
  ## Getter, maximum profit value for the current item list. This is the
  ## aggregated value of `item.effectiveGasTip(baseFee) * item.gasLimit`
  ## over all items in the argument list `nonceData`. Note that this value
  ## is typically pretty large and sort of rounded due to the resolution
  ## of the `float64` data type.
  nonceData.profit

proc maxProfit*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef]):
              float64 =
  ## Variant of `profit()`, returns `GasPriceEx.low` if `rc.isErr`
  ## evaluates `true`.
  if rc.isOk:
    return rc.value.data.profit
  float64.low


proc eq*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.eq(nonce)

proc eq*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.eq(nonce)
  err(rc.error)


proc ge*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.ge(nonce)

proc ge*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.ge(nonce)
  err(rc.error)


proc gt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.gt(nonce)

proc gt*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.gt(nonce)
  err(rc.error)


proc le*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.le(nonce)

proc le*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.le(nonce)
  err(rc.error)


proc lt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.lt(nonce)

proc lt*(rc: SortedSetResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator accounts*(gt: var TxSenderTab): (EthAddress,int64) =
  ## Sender account traversal, returns the account address and the rank
  ## for that account.
  for p in gt.addrList.nextPairs:
    yield (p.key, p.data.getRank)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Table: `status` > `nonce`
## ==========================================
##

import
  ../tx_info,
  ../tx_item,
  eth/common,
  stew/[keyed_queue, keyed_queue/kq_debug, sorted_set],
  results

{.push raises: [].}

type
  TxStatusNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` or `TxItemRef` insertion order.
    nonceList: SortedSet[AccountNonce,TxItemRef]

  TxStatusSenderRef* = ref object ##\
    ## Per address table. This table is provided as a keyed queue so deletion\
    ## while traversing is supported and predictable.
    size: int                           ## Total number of items
    gasLimits: GasInt                   ## Accumulated gas limits
    addrList: KeyedQueue[EthAddress,TxStatusNonceRef]

  TxStatusTab* = object ##\
    ## Per status table
    size: int                           ## Total number of items
    statusList: array[TxItemStatus,TxStatusSenderRef]

  TxStatusInx = object ##\
    ## Internal access data
    addrData: TxStatusSenderRef
    nonceData: TxStatusNonceRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `$`(rq: TxStatusNonceRef): string {.gcsafe, raises: [].} =
  ## Needed by `rq.verify()` for printing error messages
  $rq.nonceList.len

proc nActive(sq: TxStatusTab): int {.gcsafe, raises: [].} =
  ## Number of non-nil items
  for status in TxItemStatus:
    if not sq.statusList[status].isNil:
      result.inc

proc mkInxImpl(sq: var TxStatusTab; item: TxItemRef): Result[TxStatusInx,void]
    {.gcsafe,raises: [KeyError].} =
  ## Fails if item exists, already
  var inx: TxStatusInx

  # array of buckets (aka status) => senders
  inx.addrData = sq.statusList[item.status]
  if inx.addrData.isNil:
    new inx.addrData
    inx.addrData.addrList.init
    sq.statusList[item.status] = inx.addrData

  # sender address sub-list => nonces
  if inx.addrData.addrList.hasKey(item.sender):
    inx.nonceData = inx.addrData.addrList[item.sender]
  else:
    new inx.nonceData
    inx.nonceData.nonceList.init
    inx.addrData.addrList[item.sender] = inx.nonceData

  # nonce sublist
  let rc = inx.nonceData.nonceList.insert(item.tx.nonce)
  if rc.isErr:
    return err()
  rc.value.data = item

  return ok(inx)


proc getInxImpl(sq: var TxStatusTab; item: TxItemRef): Result[TxStatusInx,void]
    {.gcsafe,raises: [KeyError].} =
  var inx: TxStatusInx

  # array of buckets (aka status) => senders
  inx.addrData = sq.statusList[item.status]
  if inx.addrData.isNil:
    return err()

  # sender address sub-list => nonces
  if not inx.addrData.addrList.hasKey(item.sender):
    return err()
  inx.nonceData = inx.addrData.addrList[item.sender]

  ok(inx)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc init*(sq: var TxStatusTab; size = 10) {.gcsafe, raises: [].} =
  ## Optional constructor
  sq.size = 0
  sq.statusList.reset


proc insert*(sq: var TxStatusTab; item: TxItemRef): bool
    {.gcsafe,raises: [KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already (apart from returning `false`.)
  let rc = sq.mkInxImpl(item)
  if rc.isOk:
    let inx = rc.value
    sq.size.inc
    inx.addrData.size.inc
    inx.addrData.gasLimits += item.tx.gasLimit
    return true


proc delete*(sq: var TxStatusTab; item: TxItemRef): bool
    {.gcsafe,raises: [KeyError].} =
  let rc = sq.getInxImpl(item)
  if rc.isOk:
    let inx = rc.value

    sq.size.dec
    inx.addrData.size.dec
    inx.addrData.gasLimits -= item.tx.gasLimit

    discard inx.nonceData.nonceList.delete(item.tx.nonce)
    if inx.nonceData.nonceList.len == 0:
      discard inx.addrData.addrList.delete(item.sender)

    if inx.addrData.addrList.len == 0:
      sq.statusList[item.status] = nil

    return true


proc verify*(sq: var TxStatusTab): Result[void,TxInfo]
    {.gcsafe,raises: [CatchableError].} =
  ## walk `TxItemStatus` > `EthAddress` > `AccountNonce`

  var totalCount = 0
  for status in TxItemStatus:
    let addrData = sq.statusList[status]
    if not addrData.isNil:

      block:
        let rc = addrData.addrList.verify
        if rc.isErr:
          return err(txInfoVfyStatusSenderList)
      var
        addrCount = 0
        gasLimits = 0.GasInt
      for p in addrData.addrList.nextPairs:
        # let (addrKey, nonceData) = (p.key, p.data) -- notused
        let nonceData = p.data

        block:
          let rc = nonceData.nonceList.verify
          if rc.isErr:
            return err(txInfoVfyStatusNonceList)

        var rcNonce = nonceData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = nonceData.nonceList.gt(nonceKey)

          gasLimits += item.tx.gasLimit
          addrCount.inc

      if addrCount != addrData.size:
        return err(txInfoVfyStatusTotal)
      if gasLimits != addrData.gasLimits:
        return err(txInfoVfyStatusGasLimits)

      totalCount += addrCount

  # end while
  if totalCount != sq.size:
    return err(txInfoVfyStatusTotal)

  ok()

# ------------------------------------------------------------------------------
# Public  array ops -- `TxItemStatus` (level 0)
# ------------------------------------------------------------------------------

proc len*(sq: var TxStatusTab): int =
  sq.nActive

proc nItems*(sq: var TxStatusTab): int =
  ## Getter, total number of items in the list
  sq.size

proc eq*(sq: var TxStatusTab; status: TxItemStatus):
       SortedSetResult[TxItemStatus,TxStatusSenderRef] =
  let addrData = sq.statusList[status]
  if addrData.isNil:
    return err(rbNotFound)
  toSortedSetResult(key = status, data = addrData)

# ------------------------------------------------------------------------------
# Public array ops -- `EthAddress` (level 1)
# ------------------------------------------------------------------------------

proc nItems*(addrData: TxStatusSenderRef): int =
  ## Getter, total number of items in the sub-list
  addrData.size

proc nItems*(rc: SortedSetResult[TxItemStatus,TxStatusSenderRef]): int =
  if rc.isOk:
    return rc.value.data.nItems
  0


proc gasLimits*(addrData: TxStatusSenderRef): GasInt =
  ## Getter, accumulated `gasLimit` values
  addrData.gasLimits

proc gasLimits*(rc: SortedSetResult[TxItemStatus,TxStatusSenderRef]): GasInt =
  if rc.isOk:
    return rc.value.data.gasLimits
  0


proc eq*(addrData: TxStatusSenderRef; sender: EthAddress):
       SortedSetResult[EthAddress,TxStatusNonceRef]
    {.gcsafe,raises: [KeyError].} =
  if addrData.addrList.hasKey(sender):
    return toSortedSetResult(key = sender, data = addrData.addrList[sender])
  err(rbNotFound)

proc eq*(rc: SortedSetResult[TxItemStatus,TxStatusSenderRef];
         sender: EthAddress): SortedSetResult[EthAddress,TxStatusNonceRef]
    {.gcsafe,raises: [KeyError].} =
  if rc.isOk:
    return rc.value.data.eq(sender)
  err(rc.error)

# ------------------------------------------------------------------------------
# Public array ops -- `AccountNonce` (level 2)
# ------------------------------------------------------------------------------

proc len*(nonceData: TxStatusNonceRef): int =
  ## Getter, same as `nItems` (for last level list)
  nonceData.nonceList.len

proc nItems*(nonceData: TxStatusNonceRef): int =
  ## Getter, total number of items in the sub-list
  nonceData.nonceList.len

proc nItems*(rc: SortedSetResult[EthAddress,TxStatusNonceRef]): int =
  if rc.isOk:
    return rc.value.data.nItems
  0


proc eq*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.eq(nonce)

proc eq*(rc: SortedSetResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.eq(nonce)
  err(rc.error)


proc ge*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.ge(nonce)

proc ge*(rc: SortedSetResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.ge(nonce)
  err(rc.error)


proc gt*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.gt(nonce)

proc gt*(rc: SortedSetResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.gt(nonce)
  err(rc.error)


proc le*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.le(nonce)

proc le*(rc: SortedSetResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.le(nonce)
  err(rc.error)


proc lt*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  nonceData.nonceList.lt(nonce)

proc lt*(rc: SortedSetResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SortedSetResult[AccountNonce,TxItemRef] =
  if rc.isOk:
    return rc.value.data.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

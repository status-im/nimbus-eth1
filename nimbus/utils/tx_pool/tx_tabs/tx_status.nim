# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  ../../slst,
  ../tx_info,
  ../tx_item,
  eth/[common],
  stew/results

type
  TxStatusNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` or `TxItemRef` insertion order
    nonceList: Slst[AccountNonce,TxItemRef]

  TxStatusSenderRef* = ref object ##\
    ## Per address table
    size: int
    addrList: Slst[EthAddress,TxStatusNonceRef]

  TxStatusTab* = object ##\
    ## Per status table
    size: int
    statusList: array[TxItemStatus,TxStatusSenderRef]

  TxStatusInx = object ##\
    ## Internal access data
    addrData: TxStatusSenderRef
    nonceData: TxStatusNonceRef

const
  minEthAddress = block:
    var rc: EthAddress
    rc

  maxEthAddress = block:
    var rc: EthAddress
    for n in 0 ..< rc.len:
      rc[n] = 255
    rc

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `$`(rq: TxStatusNonceRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.nonceList.len

proc nActive(sq: TxStatusTab): int {.inline.} =
  ## Number of non-nil items
  for status in TxItemStatus:
    if not sq.statusList[status].isNil:
      result.inc

proc cmp(a,b: EthAddress): int {.inline.} =
  ## mixin for SLst
  for n in 0 ..< EthAddress.len:
    if a[n] < b[n]:
      return -1
    if b[n] < a[n]:
      return 1

proc mkInxImpl(sq: var TxStatusTab; item: TxItemRef): Result[TxStatusInx,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Fails if item exists, already
  var inx: TxStatusInx

  # array of buckets (aka status) => senders
  inx.addrData = sq.statusList[item.status]
  if inx.addrData.isNil:
    new inx.addrData
    inx.addrData.addrList.init
    sq.statusList[item.status] = inx.addrData

  # sender address sub-list => nonces
  block:
    let rc = inx.addrData.addrList.insert(item.sender)
    if rc.isOk:
      new inx.nonceData
      inx.nonceData.nonceList.init
      rc.value.data = inx.nonceData
    else:
      inx.nonceData = inx.addrData.addrList.eq(item.sender).value.data

  # nonce sublist
  let rc = inx.nonceData.nonceList.insert(item.tx.nonce)
  if rc.isErr:
    return err()
  rc.value.data = item

  return ok(inx)


proc getInxImpl(sq: var TxStatusTab; item: TxItemRef): Result[TxStatusInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inx: TxStatusInx

  # array of buckets (aka status) => senders
  inx.addrData = sq.statusList[item.status]
  if inx.addrData.isNil:
    return err()

  # sender address sub-list => nonces
  let rc = inx.addrData.addrList.eq(item.sender)
  if rc.isErr:
    return err()
  inx.nonceData = rc.value.data

  ok(inx)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(sq: var TxStatusTab; size = 10) =
  ## Optional constructor
  sq.size = 0
  sq.statusList.reset


proc txInsert*(sq: var TxStatusTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let rc = sq.mkInxImpl(item)
  if rc.isOK:
    let inx = rc.value
    sq.size.inc
    inx.addrData.size.inc


proc txDelete*(sq: var TxStatusTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = sq.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    sq.size.dec
    inx.addrData.size.dec

    discard inx.nonceData.nonceList.delete(item.tx.nonce)
    if inx.nonceData.nonceList.len == 0:
      discard inx.addrData.addrList.delete(item.sender)

    if inx.addrData.addrList.len == 0:
      sq.statusList[item.status] = nil

    return true


proc txVerify*(sq: var TxStatusTab): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
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
        rcAddr = addrData.addrList.ge(minEthAddress)
      while rcAddr.isOK:
        let (addrKey, nonceData) = (rcAddr.value.key, rcAddr.value.data)
        rcAddr = addrData.addrList.gt(addrKey)

        block:
          let rc = nonceData.nonceList.verify
          if rc.isErr:
            return err(txInfoVfyStatusNonceList)
        var rcNonce = nonceData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOK:
          let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = nonceData.nonceList.gt(nonceKey)

        addrCount += nonceData.nonceList.len

      if addrCount != addrData.size:
        return err(txInfoVfyStatusTotal)

      totalCount += addrCount

  # end while
  if totalCount != sq.size:
    return err(txInfoVfyStatusTotal)

  ok()

# ------------------------------------------------------------------------------
# Public  array ops -- `TxItemStatus` (level 0)
# ------------------------------------------------------------------------------

proc len*(sq: var TxStatusTab): int {.inline.} =
  sq.nActive

proc nItems*(sq: var TxStatusTab): int {.inline.} =
  ## Getter, total number of items in the list
  sq.size

proc eq*(sq: var TxStatusTab; status: TxItemStatus):
       SLstResult[TxItemStatus,TxStatusSenderRef] {.inline.} =
  let addrData = sq.statusList[status]
  if addrData.isNil:
    return err(rbNotFound)
  toSLstResult(key = status, data = addrData)

# ------------------------------------------------------------------------------
# Public array ops -- `EthAddress` (level 1)
# ------------------------------------------------------------------------------

proc nItems*(addrData: TxStatusSenderRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  addrData.size

proc nItems*(rc: SLstResult[TxItemStatus,TxStatusSenderRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc eq*(addrData: TxStatusSenderRef; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  addrData.addrList.eq(sender)

proc eq*(rc: SLstResult[TxItemStatus,TxStatusSenderRef]; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.eq(sender)
  err(rc.error)


proc ge*(addrData: TxStatusSenderRef; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  addrData.addrList.ge(sender)

proc ge*(rc: SLstResult[TxItemStatus,TxStatusSenderRef]; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.ge(sender)
  err(rc.error)


proc gt*(addrData: TxStatusSenderRef; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  addrData.addrList.gt(sender)

proc gt*(rc: SLstResult[TxItemStatus,TxStatusSenderRef]; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.gt(sender)
  err(rc.error)


proc le*(addrData: TxStatusSenderRef; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  addrData.addrList.le(sender)

proc le*(rc: SLstResult[TxItemStatus,TxStatusSenderRef]; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.le(sender)
  err(rc.error)


proc lt*(addrData: TxStatusSenderRef; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  addrData.addrList.lt(sender)

proc lt*(rc: SLstResult[TxItemStatus,TxStatusSenderRef]; sender: EthAddress):
       SLstResult[EthAddress,TxStatusNonceRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.lt(sender)
  err(rc.error)

# ------------------------------------------------------------------------------
# Public array ops -- `AccountNonce` (level 2)
# ------------------------------------------------------------------------------

proc nItems*(nonceData: TxStatusNonceRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  nonceData.nonceList.len

proc nItems*(rc: SLstResult[EthAddress,TxStatusNonceRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc eq*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.eq(nonce)

proc eq*(rc: SLstResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.eq(nonce)
  err(rc.error)


proc ge*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.ge(nonce)

proc ge*(rc: SLstResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.ge(nonce)
  err(rc.error)


proc gt*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.gt(nonce)

proc gt*(rc: SLstResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.gt(nonce)
  err(rc.error)


proc le*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.le(nonce)

proc le*(rc: SLstResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.le(nonce)
  err(rc.error)


proc lt*(nonceData: TxStatusNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.lt(nonce)

proc lt*(rc: SLstResult[EthAddress,TxStatusNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

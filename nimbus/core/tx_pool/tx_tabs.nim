# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[tables, heapqueue],
  eth/common/base,
  eth/common/addresses,
  eth/common/hashes,
  stew/sorted_set,
  ../../db/ledger,
  ./tx_item

type
  SenderNonceList* = SortedSet[AccountNonce, TxItemRef]

  TxSenderNonceRef* = ref object
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    list*: SenderNonceList

  TxSenderTab* = Table[Address, TxSenderNonceRef]

  TxIdTab* = Table[Hash32, TxItemRef]

func init*(_ : type TxSenderNonceRef): TxSenderNonceRef =
  TxSenderNonceRef(list: SenderNonceList.init())

template insertOrReplace*(sn: TxSenderNonceRef, item: TxItemRef) =
  sn.list.findOrInsert(item.nonce).
    expect("insert txitem ok").data = item

func last*(sn: TxSenderNonceRef): auto  =
  sn.list.le(AccountNonce.high)

func len*(sn: TxSenderNonceRef): auto  =
  sn.list.len

iterator byPriceAndNonce*(senderTab: TxSenderTab,
                          idTab: var TxIdTab,
                          ledger: LedgerRef,
                          baseFee: GasInt): TxItemRef =
  template removeFirstAndPushTo(sn, byPrice) =
    let rc = sn.list.ge(AccountNonce.low).valueOr:
      continue
    discard sn.list.delete(rc.data.nonce)
    byPrice.push(rc.data)

  var byNonce: TxSenderTab
  for address, sn in senderTab:    
    var
      nonce = ledger.getNonce(address)      
      sortedByNonce: TxSenderNonceRef
    
    # Remove item with nonce lower than current account.
    # Happen when proposed block rejected.
    var rc = sn.list.lt(nonce)
    while rc.isOk:
      let item = rc.get.data
      idTab.del(item.id)
      discard sn.list.delete(item.nonce)
      rc = sn.list.lt(nonce)
    
    # Check if the account nonce matches the lowest known tx nonce
    rc = sn.list.ge(nonce)
    while rc.isOk:
      let item = rc.get.data
      item.calculatePrice(baseFee)
      
      if sortedByNonce.isNil:
        sortedByNonce = TxSenderNonceRef.init()
        byNonce[address] = sortedByNonce

      sortedByNonce.insertOrReplace(item)
      # If there is a gap, sn.list.eq will return isErr
      nonce = item.nonce + 1
      rc = sn.list.eq(nonce)

  # HeapQueue needs `<` to be overloaded for custom object
  # and in this case, we want to pop highest price first
  func `<`(a, b: TxItemRef): bool {.used.} = a.price > b.price
  var byPrice = initHeapQueue[TxItemRef]()
  for _, sn in byNonce:
    sn.removeFirstAndPushTo(byPrice)

  while byPrice.len > 0:
    # Retrieve the next best transaction by price
    let best = byPrice.pop()

    # Push in its place the next transaction from the same account
    let sn = byNonce.getOrDefault(best.sender)
    if sn.isNil.not and sn.len > 0:
      sn.removeFirstAndPushTo(byPrice)

    yield best

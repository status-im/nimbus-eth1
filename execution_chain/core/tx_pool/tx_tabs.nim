# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
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

  BlobLookup* = object
    item*: TxItemRef
    blobIndex*: int

  BlobLookupTab* = Table[Hash32, BlobLookup]

func init*(_ : type TxSenderNonceRef): TxSenderNonceRef =
  TxSenderNonceRef(list: SenderNonceList.init())

template insertOrReplace*(sn: TxSenderNonceRef, item: TxItemRef) =
  sn.list.findOrInsert(item.nonce).
    expect("insert txitem ok").data = item

func len*(sn: TxSenderNonceRef): auto  =
  sn.list.len

func addLookup*(blobTab: var BlobLookupTab, item: TxItemRef) =
  for i, v in item.tx.versionedHashes:
    blobTab[v] = BlobLookup(item: item, blobIndex: i)

func removeLookup*(blobTab: var BlobLookupTab, item: TxItemRef) =
  for v in item.tx.versionedHashes:
    blobTab.del(v)

iterator byPriceAndNonce*(senderTab: TxSenderTab,
                          idTab: var TxIdTab,
                          blobTab: var BlobLookupTab,
                          ledger: LedgerRef,
                          baseFee: GasInt): TxItemRef =

  ## This algorithm and comment is taken from ethereumjs but modified.
  ##
  ## Returns eligible txs to be packed sorted by price in such a way that the
  ## nonce orderings within a single account are maintained.
  ##
  ## Note, this is not as trivial as it seems from the first look as there are three
  ## different criteria that need to be taken into account (price, nonce, account
  ## match), which cannot be done with any plain sorting method, as certain items
  ## cannot be compared without context.
  ##
  ## This method first sorts the list of transactions into individual
  ## sender accounts and sorts them by nonce.
  ##    -- This is done by senderTab internal algorithm.
  ##
  ## After the account nonce ordering is satisfied, the results are merged back
  ## together by price, always comparing only the head transaction from each account.
  ## This is done via a heap to keep it fast.
  ##
  ## @param baseFee Provide a baseFee to exclude txs with a lower gasPrice
  ##

  template getHeadAndPushTo(sn, byPrice, nonce) =
    let rc = sn.list.ge(nonce)
    if rc.isOk:
      let item = rc.get.data
      item.calculatePrice(baseFee)
      byPrice.push(item)

  # HeapQueue needs `<` to be overloaded for custom object
  # and in this case, we want to pop highest price first.
  # That's why we use '>' instead of '<' in the implementation.
  func `<`(a, b: TxItemRef): bool {.used.} = a.price > b.price
  var byPrice = initHeapQueue[TxItemRef]()

  # Fill byPrice with `head item` from each account.
  # The `head item` is the lowest allowed nonce.
  for address, sn in senderTab:
    let nonce = ledger.getNonce(address)

    # Remove item with nonce lower than current account's nonce.
    # Happen when proposed block rejected.
    # removeNewBlockTxs will also remove this kind of txs,
    # but in a less explicit way. And probably less thoroughly.
    # EMV will reject the transaction too, but we filter it here
    # for efficiency.
    var rc = sn.list.lt(nonce)
    while rc.isOk:
      let item = rc.get.data
      idTab.del(item.id)
      blobTab.removeLookup(item)
      discard sn.list.delete(item.nonce)
      rc = sn.list.lt(nonce)

    # Check if the account nonce matches the lowest known tx nonce.
    sn.getHeadAndPushTo(byPrice, nonce)

  while byPrice.len > 0:
    # Retrieve the next best transaction by price.
    let best = byPrice.pop()

    # Push in its place the next transaction from the same account.
    let sn = senderTab.getOrDefault(best.sender)
    if sn.isNil.not:
      # This algorithm will automatically reject
      # transaction with nonce gap(best.nonce + 1)
      # EVM will reject this kind transaction too, but
      # why do expensive EVM call when we can do it cheaply here.
      # We don't remove transactions with gap like we do with transactions
      # of lower nonce? because they might be  packed by future blocks
      # when the gap is filled. Worst case is they will expired and get purged by
      # `removeExpiredTxs`
      sn.getHeadAndPushTo(byPrice, best.nonce + 1)

    yield best

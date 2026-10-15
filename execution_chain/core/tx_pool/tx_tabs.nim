# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
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
  ../../common/evmforks,
  ../pooled_txs,
  ./tx_item

type
  SenderNonceList* = SortedSet[AccountNonce, TxItemRef]

  TxSenderNonceRef* = ref object
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    list*: SenderNonceList

  TxSenderTab* = Table[Address, TxSenderNonceRef]

  TxIdTab* = OrderedTable[Hash32, TxItemRef]

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

# HeapQueue needs `<` to be overloaded for custom object
# and in this case, we want to pop highest price first.
# That's why we use '>' instead of '<' in the implementation.
func `<`(a, b: TxItemRef): bool = a.price > b.price

proc validBlobItem(item: TxItemRef;
                   fork: EVMFork;
                   sn: TxSenderNonceRef;
                   idTab: var TxIdTab;
                   blobTab: var BlobLookupTab;
                   ): bool =
  let wrapperVersion = item.wrapperVersion.valueOr:
    # Without blobs is ok
    return true

  if fork < FkCancun:
    # No blobs allowed
    return false

  case wrapperVersion
  of WrapperVersionEIP4844:
    if fork >= FkOsaka:
      # Should not exist anymore
      idTab.del(item.id)
      blobTab.removeLookup(item)
      discard sn.list.delete(item.nonce)
      return false

  of WrapperVersionEIP7594:
    if fork < FkOsaka:
      # Not participate in block building but maybe eligible for next fork
      return false

  true

iterator byPriceAndNonce*(senderTab: TxSenderTab,
                          idTab: var TxIdTab,
                          blobTab: var BlobLookupTab,
                          ledger: LedgerRef,
                          baseFee: GasInt,
                          fork: EVMFork): TxItemRef =

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
  ## The caller is expected to execute every yielded transaction against
  ## `ledger`. A sender's next transaction is only offered once the account
  ## nonce has moved past the yielded one; if it did not move, the transaction
  ## was not included and none of the sender's later ones can be either.
  ##
  ## @param baseFee Provide a baseFee to exclude txs with a lower gasPrice
  ##

  template getHeadAndPushTo(sn, byPrice, nonce) =
    # Transactions after a nonce gap cannot be included, skip them
    let rc = sn.list.eq(nonce)
    if rc.isOk:
      let item = rc.get.data
      if item.validBlobItem(fork, sn, idTab, blobTab):
        item.calculatePrice(baseFee)
        byPrice.push(item)

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

    yield best

    # Push in its place the transaction for the account nonce `best` left
    # behind. The nonce moved past `best` if it was included, or if an EIP-7702
    # authorization in another transaction bumped it and made `best` stale.
    # Otherwise `best` was not included, so the sender is done for this block.
    # Transactions with a nonce gap are not removed like the stale ones above:
    # they might be packed by future blocks once the gap is filled. Worst case
    # they expire and get purged by `removeExpiredTxs`.
    let nonce = ledger.getNonce(best.sender)
    if nonce > best.nonce:
      let sn = senderTab.getOrDefault(best.sender)
      if sn.isNil.not:
        sn.getHeadAndPushTo(byPrice, nonce)

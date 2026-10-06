# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# Builder for constructing a BlockAccessList efficiently during transaction
# execution. The builder accumulates all account and storage reads and writes
# during block execution and constructs a deterministic access list. Changes
# are tracked by address, field type, and block access list index to enable
# efficient reconstruction of state changes.
#
# All collections use the non-GC SharedSeq/SmallSeq types (rather than the
# standard library Seq) so that the builder can be used safely with the refc
# memory manager across threads. The touched account, balance and nonce
# collections keep inline room for a plain transfer (sender, recipient and
# coinbase) so that such a transaction records its changes without any heap
# allocation, while keeping the per-index record small enough that heavier
# transactions do not pay for unused inline space in their cache footprint.
#
# The idea here is that each thread writes to a separate index in the internal
# `perIndex` array so that concurrent lock free writes are possible during
# parallel execution.

{.push raises: [], gcsafe.}

import
  std/[algorithm, tables],
  eth/common/[block_access_lists, block_access_lists_rlp],
  stint,
  ../concurrency/shared_types

export block_access_lists

type
  StorageWrite = tuple[address: Address, slot: UInt256, value: UInt256]
  StorageReadEntry = tuple[address: Address, slot: UInt256]
  BalanceWrite = tuple[address: Address, balance: UInt256]
  NonceWrite = tuple[address: Address, nonce: AccountNonce]
  CodeWrite = tuple[address: Address, code: SharedBytes]

const
  inlineTouchedAccounts = 3
  inlineBalanceChanges = 3
  inlineNonceChanges = 1

type
  BalIndexData = object
    touchedAccounts: SmallSeq[inlineTouchedAccounts, Address]
    storageChanges: SharedSeq[StorageWrite]
    storageReads: SharedSeq[StorageReadEntry]
    balanceChanges: SmallSeq[inlineBalanceChanges, BalanceWrite]
    nonceChanges: SmallSeq[inlineNonceChanges, NonceWrite]
    codeChanges: SharedSeq[CodeWrite]

  BlockAccessListBuilder* = object
    perIndex: SharedSeq[BalIndexData]

proc dispose(indexData: var BalIndexData) =
  indexData.touchedAccounts.dispose()
  indexData.storageChanges.dispose()
  indexData.storageReads.dispose()
  indexData.balanceChanges.dispose()
  indexData.nonceChanges.dispose()
  for code in indexData.codeChanges.mitems():
    code.code.dispose()
  indexData.codeChanges.dispose()

proc `=copy`(
    dest: var BalIndexData, src: BalIndexData
) {.error: "Copying BalIndexData is forbidden".} =
  discard

proc init*(builder: var BlockAccessListBuilder) =
  # Is a no-op because the perIndex array is zero initialized
  # and valid with default values.
  discard

proc newShared*(T: type BlockAccessListBuilder): ptr BlockAccessListBuilder =
  let builderPtr = createShared(BlockAccessListBuilder)
  builderPtr[].init()
  builderPtr

proc dispose*(builder: var BlockAccessListBuilder) =
  for idxData in builder.perIndex.mitems():
    idxData.dispose()
  builder.perIndex.dispose()

proc dispose*(builderPtr: ptr BlockAccessListBuilder) =
  if not builderPtr.isNil():
    builderPtr[].dispose()
    deallocShared(builderPtr)

proc `=copy`(
    dest: var BlockAccessListBuilder, src: BlockAccessListBuilder
) {.error: "Copying BlockAccessListBuilder is forbidden".} =
  discard

proc ensureIndexCount*(builder: var BlockAccessListBuilder, n: int, exact = false) =
  if n > builder.perIndex.len:
    builder.perIndex.setLen(n, zeroed = true, exact)

proc addTouchedAccount*(
    builder: var BlockAccessListBuilder, blockAccessIndex: int, address: Address
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].touchedAccounts.add(address)

proc addStorageWrite*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    slot: UInt256,
    newValue: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].storageChanges.add((address, slot, newValue))

proc addStorageRead*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    slot: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].storageReads.add((address, slot))

proc addBalanceChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    postBalance: UInt256,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].balanceChanges.add((address, postBalance))

proc addNonceChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    newNonce: AccountNonce,
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].nonceChanges.add((address, newNonce))

proc addCodeChange*(
    builder: var BlockAccessListBuilder,
    blockAccessIndex: int,
    address: Address,
    newCode: openArray[byte],
) =
  assert blockAccessIndex < builder.perIndex.len
  builder.perIndex[blockAccessIndex].codeChanges.add(
    (address, SharedBytes.init(newCode))
  )

type
  # Flattened per-index writes, tagged with a dense account id instead of the
  # address so that grouping by account is a counting sort rather than a
  # comparison sort over 20-byte keys.
  FlatStorageChange =
    tuple[acct: int32, index: BlockAccessIndex, slot: UInt256, value: UInt256]
  FlatStorageRead = tuple[acct: int32, slot: UInt256]
  FlatBalanceChange = tuple[acct: int32, index: BlockAccessIndex, value: UInt256]
  FlatNonceChange = tuple[acct: int32, index: BlockAccessIndex, value: AccountNonce]
  FlatCodeChange = tuple[acct: int32, index: BlockAccessIndex, value: seq[byte]]

  AccountIds = object
    ids: Table[Address, int32]
    addresses: seq[Address] ## address of each id, in first-seen order

func idOf(accounts: var AccountIds, address: Address): int32 =
  let next = int32(accounts.addresses.len)
  result = accounts.ids.mgetOrPut(address, next)
  if result == next:
    accounts.addresses.add(address)

func addrCmp(x, y: Address): int =
  cmpMem(unsafeAddr x, unsafeAddr y, sizeof(Address))

func slotCmp[T: FlatStorageChange | FlatStorageRead](x, y: T): int =
  cmp(x.slot, y.slot)

func groupByAccount[T](
    entries: seq[T], numAccounts: int, grouped: var seq[T], offsets: var seq[int32]
) =
  ## Stable counting sort of `entries` by account id into `grouped`. The entries
  ## of account `i` end up in `grouped[offsets[i] ..< offsets[i + 1]]`, keeping
  ## their relative (block access index) order.
  offsets = newSeq[int32](numAccounts + 1)
  for e in entries:
    inc offsets[e.acct + 1]
  for i in 1 .. numAccounts:
    offsets[i] += offsets[i - 1]

  grouped = newSeq[T](entries.len)
  var cursor = offsets
  for i in 0 ..< entries.len:
    let acct = entries[i].acct
    grouped[cursor[acct]] = entries[i]
    inc cursor[acct]

func sortBySlot[T](entries: var seq[T], lo, hi: int) =
  ## Stable sort of `entries[lo ..< hi]` by slot. The range is already in block
  ## access index order so the result is ordered by (slot, index). Small ranges,
  ## which is most accounts, are insertion sorted to avoid the merge sort's
  ## temporary buffer.
  const insertionLimit = 24
  if hi - lo <= 1:
    return
  if hi - lo <= insertionLimit:
    for i in lo + 1 ..< hi:
      var j = i
      while j > lo and slotCmp(entries[j - 1], entries[j]) > 0:
        swap(entries[j - 1], entries[j])
        dec j
  else:
    sort(entries.toOpenArray(lo, hi - 1), slotCmp[T])

func countDistinctIndices[T](src: seq[T], lo, hi: int): int =
  ## Number of distinct block access indices in `src[lo ..< hi]`, which is in
  ## index order.
  var i = lo
  while i < hi:
    let index = src[i].index
    inc i
    while i < hi and src[i].index == index:
      inc i
    inc result

func seqOfCap[T](n: int): seq[T] =
  ## Like newSeqOfCap but leaves an empty seq unallocated, which most of the
  ## per-account output seqs are.
  if n > 0:
    newSeqOfCap[T](n)
  else:
    default(seq[T])

template collapseByIndex[T](src: seq[T], lo, hi: int, emit: untyped) =
  ## `src[lo ..< hi]` is in block access index order. Run `emit` once per distinct
  ## `index` with the last `value` seen for that index injected, reproducing
  ## last-write-wins for the pre/post-execution indices, which are the only ones
  ## that can repeat.
  var cursor = lo
  while cursor < hi:
    let index {.inject.} = src[cursor].index
    var value {.inject.} = src[cursor].value
    inc cursor
    while cursor < hi and src[cursor].index == index:
      value = src[cursor].value
      inc cursor
    emit

func buildBlockAccessList*(builder: var BlockAccessListBuilder): BlockAccessListRef =
  # Not thread safe: only call once all threads have finished writing.
  #
  # Rebuild is done in three phases:
  #   1. assign a dense id to every address and flatten every per-index write
  #      into flat, id-tagged seqs (which are therefore in index order),
  #   2. group each seq by account with a stable counting sort and sort each
  #      account's storage entries by slot,
  #   3. emit one AccountChanges per account in address order.
  let blockAccessList = new BlockAccessList

  # Phase 1: reserve exact capacity, then flatten.
  var totS, totR, totB, totN, totC = 0
  for idx in 0 ..< builder.perIndex.len:
    let d = addr builder.perIndex[idx]
    totS += d[].storageChanges.len
    totR += d[].storageReads.len
    totB += d[].balanceChanges.len
    totN += d[].nonceChanges.len
    totC += d[].codeChanges.len

  var
    accounts: AccountIds
    sFlat = newSeqOfCap[FlatStorageChange](totS)
    rFlat = newSeqOfCap[FlatStorageRead](totR)
    bFlat = newSeqOfCap[FlatBalanceChange](totB)
    nFlat = newSeqOfCap[FlatNonceChange](totN)
    cFlat = newSeqOfCap[FlatCodeChange](totC)

  for idx in 0 ..< builder.perIndex.len:
    let
      balIndex = BlockAccessIndex(idx)
      d = addr builder.perIndex[idx]
    for a in d[].touchedAccounts.items():
      discard accounts.idOf(a)
    for w in d[].storageChanges.items():
      sFlat.add((accounts.idOf(w.address), balIndex, w.slot, w.value))
    for r in d[].storageReads.items():
      rFlat.add((accounts.idOf(r.address), r.slot))
    for b in d[].balanceChanges.items():
      bFlat.add((accounts.idOf(b.address), balIndex, b.balance))
    for nc in d[].nonceChanges.items():
      nFlat.add((accounts.idOf(nc.address), balIndex, nc.nonce))
    for cc in d[].codeChanges.items():
      cFlat.add((accounts.idOf(cc.address), balIndex, cc.code.data()))

  let numAccounts = accounts.addresses.len

  # Phase 2: group by account, then order each account's storage entries by
  # slot. Balance, nonce and code entries need no sorting: grouping is stable
  # and the flat seqs are in index order.
  var
    sChanges: seq[FlatStorageChange]
    sReads: seq[FlatStorageRead]
    bChanges: seq[FlatBalanceChange]
    nChanges: seq[FlatNonceChange]
    cChanges: seq[FlatCodeChange]
    sOff, rOff, bOff, nOff, cOff: seq[int32]
  groupByAccount(sFlat, numAccounts, sChanges, sOff)
  groupByAccount(rFlat, numAccounts, sReads, rOff)
  groupByAccount(bFlat, numAccounts, bChanges, bOff)
  groupByAccount(nFlat, numAccounts, nChanges, nOff)
  groupByAccount(cFlat, numAccounts, cChanges, cOff)

  for id in 0 ..< numAccounts:
    sChanges.sortBySlot(sOff[id], sOff[id + 1])
    sReads.sortBySlot(rOff[id], rOff[id + 1])

  var order = newSeqOfCap[tuple[address: Address, id: int32]](numAccounts)
  for id in 0 ..< numAccounts:
    order.add((accounts.addresses[id], int32(id)))
  sort(order) do(x, y: tuple[address: Address, id: int32]) -> int:
    addrCmp(x.address, y.address)

  # Phase 3: emit per account. Every output seq is written in place through
  # the final BlockAccessList rather than built in a local and moved, since a
  # seq move under refc is a deep copy.
  blockAccessList[].setLen(numAccounts)
  for k, (acc, id) in order:
    template acct(): untyped =
      blockAccessList[][k]

    acct.address = acc

    # storageChanges: group by slot, then collapse each slot's writes by index.
    let
      sLo = int(sOff[id])
      sHi = int(sOff[id + 1])
    var
      numSlots = 0
      si = sLo
    while si < sHi:
      let slot = sChanges[si].slot
      inc si
      while si < sHi and sChanges[si].slot == slot:
        inc si
      inc numSlots

    if numSlots > 0:
      acct.storageChanges.setLen(numSlots)
    var slotIdx = 0
    si = sLo
    while si < sHi:
      let slot = sChanges[si].slot
      var slotHi = si
      while slotHi < sHi and sChanges[slotHi].slot == slot:
        inc slotHi
      template slotChanges(): untyped =
        acct.storageChanges[slotIdx]

      slotChanges.slot = StorageKey(slot)
      slotChanges.changes =
        seqOfCap[StorageChange](sChanges.countDistinctIndices(si, slotHi))
      collapseByIndex(sChanges, si, slotHi):
        slotChanges.changes.add((index, StorageValue(value)))
      inc slotIdx
      si = slotHi

    # storageReads: unique read slots that were not also written. Both ranges
    # are slot-sorted, so a single forward cursor (`written`) decides membership.
    let
      rLo = int(rOff[id])
      rHi = int(rOff[id + 1])
    var
      numReads = 0
      written = 0
      ri = rLo
    while ri < rHi:
      let slot = sReads[ri].slot
      inc ri
      while ri < rHi and sReads[ri].slot == slot:
        inc ri
      while written < numSlots and acct.storageChanges[written].slot < slot:
        inc written
      if written >= numSlots or acct.storageChanges[written].slot != slot:
        inc numReads

    acct.storageReads = seqOfCap[StorageKey](numReads)
    written = 0
    ri = rLo
    while ri < rHi:
      let slot = sReads[ri].slot
      inc ri
      while ri < rHi and sReads[ri].slot == slot:
        inc ri
      while written < numSlots and acct.storageChanges[written].slot < slot:
        inc written
      if written >= numSlots or acct.storageChanges[written].slot != slot:
        acct.storageReads.add(StorageKey(slot))

    let
      bLo = int(bOff[id])
      bHi = int(bOff[id + 1])
    acct.balanceChanges =
      seqOfCap[BalanceChange](bChanges.countDistinctIndices(bLo, bHi))
    collapseByIndex(bChanges, bLo, bHi):
      acct.balanceChanges.add((index, Balance(value)))

    let
      nLo = int(nOff[id])
      nHi = int(nOff[id + 1])
    acct.nonceChanges = seqOfCap[NonceChange](nChanges.countDistinctIndices(nLo, nHi))
    collapseByIndex(nChanges, nLo, nHi):
      acct.nonceChanges.add((index, Nonce(value)))

    let
      cLo = int(cOff[id])
      cHi = int(cOff[id + 1])
    acct.codeChanges = seqOfCap[CodeChange](cChanges.countDistinctIndices(cLo, cHi))
    collapseByIndex(cChanges, cLo, cHi):
      acct.codeChanges.add((index, Bytecode(value)))

  blockAccessList

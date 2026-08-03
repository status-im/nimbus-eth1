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
# All collections use the non-GC SharedSeq type (rather than the standard
# library Seq) so that the builder can be used safely with the refc memory
# manager across threads.
#
# The idea here is that each thread writes to a separate index in the internal
# `perIndex` array so that concurrent lock free writes are possible during
# parallel execution.

{.push raises: [], gcsafe.}

import
  std/[algorithm],
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

  BalIndexData = object
    touchedAccounts: SharedSeq[Address]
    storageChanges: SharedSeq[StorageWrite]
    storageReads: SharedSeq[StorageReadEntry]
    balanceChanges: SharedSeq[BalanceWrite]
    nonceChanges: SharedSeq[NonceWrite]
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
  FlatStorageChange =
    tuple[address: Address, slot: UInt256, index: BlockAccessIndex, value: UInt256]
  FlatStorageRead = tuple[address: Address, slot: UInt256]
  FlatBalanceChange =
    tuple[address: Address, index: BlockAccessIndex, value: UInt256]
  FlatNonceChange =
    tuple[address: Address, index: BlockAccessIndex, value: AccountNonce]
  FlatCodeChange =
    tuple[address: Address, index: BlockAccessIndex, value: seq[byte]]

func addrCmp(x, y: Address): int =
  let
    xd = x.data()
    yd = y.data()
  for i in 0 ..< xd.len:
    if xd[i] != yd[i]:
      return (if xd[i] < yd[i]: -1 else: 1)
  0

func flatStorageCmp(x, y: FlatStorageChange): int =
  var c = addrCmp(x.address, y.address)
  if c == 0:
    c = cmp(x.slot, y.slot)
  if c == 0:
    c = cmp(x.index, y.index)
  c

func flatStorageReadCmp(x, y: FlatStorageRead): int =
  var c = addrCmp(x.address, y.address)
  if c == 0:
    c = cmp(x.slot, y.slot)
  c

func flatIndexedCmp[T](
    x, y: tuple[address: Address, index: BlockAccessIndex, value: T]
): int =
  var c = addrCmp(x.address, y.address)
  if c == 0:
    c = cmp(x.index, y.index)
  c

func headAddress[T](src: openArray[T], cursor: int): Opt[Address] {.inline.} =
  # Address of the entry at `cursor`, or none once the cursor is exhausted.
  if cursor < src.len: Opt.some(src[cursor].address) else: Opt.none(Address)

template collapseByIndex[T](
    src: openArray[T], cursor: var int, sameGroup, emit: untyped
) =
  # `src` is sorted by index within each group. Consume the run for which
  # `sameGroup` holds and run `emit` once per distinct block access `index` with
  # the last `value` seen for that index injected - reproducing last-write-wins
  # for the pre/post-execution indices, which are the only ones that can repeat.
  while cursor < src.len and sameGroup:
    let index {.inject.} = src[cursor].index
    var value {.inject.} = src[cursor].value
    inc cursor
    while cursor < src.len and sameGroup and src[cursor].index == index:
      value = src[cursor].value
      inc cursor
    emit

func buildBlockAccessList*(builder: var BlockAccessListBuilder): BlockAccessListRef =
  # Not thread safe: only call once all threads have finished writing.
  #
  # Rebuild is done in three phases:
  #   1. flatten every per-index write into flat, address-tagged seqs,
  #   2. sort each seq by (address, [slot,] index),
  #   3. merge-walk the seqs by address, emitting one AccountChanges per address.
  let blockAccessList = new BlockAccessList

  # Phase 1: reserve exact capacity, then flatten.
  var totS, totR, totB, totN, totC, totT = 0
  for idx in 0 ..< builder.perIndex.len:
    let d = addr builder.perIndex[idx]
    totT += d[].touchedAccounts.len
    totS += d[].storageChanges.len
    totR += d[].storageReads.len
    totB += d[].balanceChanges.len
    totN += d[].nonceChanges.len
    totC += d[].codeChanges.len

  var
    touched = newSeqOfCap[Address](totT)
    sChanges = newSeqOfCap[FlatStorageChange](totS)
    sReads = newSeqOfCap[FlatStorageRead](totR)
    bChanges = newSeqOfCap[FlatBalanceChange](totB)
    nChanges = newSeqOfCap[FlatNonceChange](totN)
    cChanges = newSeqOfCap[FlatCodeChange](totC)

  for idx in 0 ..< builder.perIndex.len:
    let
      balIndex = BlockAccessIndex(idx)
      d = addr builder.perIndex[idx]
    for a in d[].touchedAccounts.items():
      touched.add(a)
    for w in d[].storageChanges.items():
      sChanges.add((w.address, w.slot, balIndex, w.value))
    for r in d[].storageReads.items():
      sReads.add((r.address, r.slot))
    for b in d[].balanceChanges.items():
      bChanges.add((b.address, balIndex, b.balance))
    for nc in d[].nonceChanges.items():
      nChanges.add((nc.address, balIndex, nc.nonce))
    for cc in d[].codeChanges.items():
      cChanges.add((cc.address, balIndex, cc.code.data()))

  # Phase 2: sort each field by (address, [slot,] index). The sort must be stable
  # so that entries sharing a key keep their append order and Phase 3's collapse
  # yields the last write per index. std/algorithm.sort is guaranteed stable.
  sort(touched, addrCmp)
  sort(sChanges, flatStorageCmp)
  sort(sReads, flatStorageReadCmp)
  sort(bChanges, flatIndexedCmp[UInt256])
  sort(nChanges, flatIndexedCmp[AccountNonce])
  sort(cChanges, flatIndexedCmp[seq[byte]])

  # Phase 3: merge-walk by address.
  var si, ri, bi, ni, ci, ti = 0
  while true:
    # Smallest address still pending across all six cursors.
    var nextAddr = Opt.none(Address)
    for head in [
        headAddress(sChanges, si), headAddress(sReads, ri), headAddress(bChanges, bi),
        headAddress(nChanges, ni), headAddress(cChanges, ci),
        (if ti < touched.len: Opt.some(touched[ti]) else: Opt.none(Address))]:
      if head.isSome and (nextAddr.isNone or addrCmp(head.get, nextAddr.get) < 0):
        nextAddr = head
    if nextAddr.isNone:
      break
    let acc = nextAddr.get

    # storageChanges: group by slot, then collapse each slot's writes by index.
    var storageChanges: seq[SlotChanges]
    while si < sChanges.len and sChanges[si].address == acc:
      let slot = sChanges[si].slot
      var slotChanges: seq[StorageChange]
      collapseByIndex(sChanges, si,
          sChanges[si].address == acc and sChanges[si].slot == slot):
        slotChanges.add((index, StorageValue(value)))
      storageChanges.add((StorageKey(slot), slotChanges))

    # storageReads: unique read slots that were not also written. Both seqs are
    # slot-sorted, so a single forward cursor (`written`) decides membership.
    var storageReads: seq[StorageKey]
    var written = 0
    while ri < sReads.len and sReads[ri].address == acc:
      let slot = sReads[ri].slot
      inc ri
      while ri < sReads.len and sReads[ri].address == acc and sReads[ri].slot == slot:
        inc ri
      while written < storageChanges.len and storageChanges[written].slot < slot:
        inc written
      if written >= storageChanges.len or storageChanges[written].slot != slot:
        storageReads.add(StorageKey(slot))

    var balanceChanges: seq[BalanceChange]
    collapseByIndex(bChanges, bi, bChanges[bi].address == acc):
      balanceChanges.add((index, Balance(value)))

    var nonceChanges: seq[NonceChange]
    collapseByIndex(nChanges, ni, nChanges[ni].address == acc):
      nonceChanges.add((index, Nonce(value)))

    var codeChanges: seq[CodeChange]
    collapseByIndex(cChanges, ci, cChanges[ci].address == acc):
      codeChanges.add((index, Bytecode(value)))

    while ti < touched.len and touched[ti] == acc:
      inc ti

    blockAccessList[].add(AccountChanges(
      address: acc,
      storageChanges: move(storageChanges),
      storageReads: move(storageReads),
      balanceChanges: move(balanceChanges),
      nonceChanges: move(nonceChanges),
      codeChanges: move(codeChanges)))

  blockAccessList

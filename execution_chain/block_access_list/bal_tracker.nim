# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/bitops,
  eth/common/addresses,
  stint,
  ../db/ledger,
  ./[bal_builder, bal_changes]

export addresses, bal_builder, ledger, stint

type
  TouchSet[K] = object
    keys: seq[K]
    buckets: seq[uint64]
    epoch: uint64
    shift: int

  BlockAccessListTrackerRef* = ref object
    ledger: LedgerRef
    builder*: ptr BlockAccessListBuilder
    builderOwner*: bool
    currentBlockAccessIndex*: int
    windowOpen: bool
    accounts: TouchSet[Address]
    slots: TouchSet[AccessedSlot]
    writeOf: seq[int32]
    changes: BalChangesRef
    blockAccessList: Opt[BlockAccessListRef]

const
  epochStep = 1'u64 shl 32
  indexMask = epochStep - 1
  epochMask = not indexMask

func hashKey(a: Address): uint64 {.inline.} =
  let p = cast[ptr UncheckedArray[byte]](unsafeAddr a)
  var
    x, y: uint64
    z: uint32
  copyMem(addr x, addr p[0], 8)
  copyMem(addr y, addr p[8], 8)
  copyMem(addr z, addr p[16], 4)
  let h =
    x xor (y * 0x9E3779B97F4A7C15'u64) xor (uint64(z) * 0xC2B2AE3D27D4EB4F'u64)
  (h xor (h shr 31)) * 0x94D049BB133111EB'u64

func hashKey(k: AccessedSlot): uint64 {.inline.} =
  let
    l = k.slot.limbs
    s =
      (l[0] * 0x9E3779B97F4A7C15'u64) xor (l[1] * 0xC2B2AE3D27D4EB4F'u64) xor
      (l[2] * 0x165667B19E3779F9'u64) xor (l[3] * 0xD6E8FEB86659FD93'u64)
    h = hashKey(k.address) xor s
  (h xor (h shr 29)) * 0xBF58476D1CE4E5B9'u64

func grow[K](s: var TouchSet[K]) {.noinline.} =
  let size = max(32, s.buckets.len * 2)
  s.buckets = newSeq[uint64](size)
  s.shift = 64 - fastLog2(size)
  if s.epoch == 0:
    s.epoch = epochStep
  let mask = size - 1
  for idx in 0 ..< s.keys.len:
    var i = int(hashKey(s.keys[idx]) shr s.shift)
    while (s.buckets[i] and epochMask) == s.epoch:
      i = (i + 1) and mask
    s.buckets[i] = s.epoch or uint64(idx + 1)

func reset[K](s: var TouchSet[K]) =
  s.keys.setLen(0)
  s.epoch += epochStep
  if s.epoch == 0:
    s.epoch = epochStep
    if s.buckets.len > 0:
      zeroMem(addr s.buckets[0], s.buckets.len * sizeof(uint64))

func incl[K](s: var TouchSet[K], key: K) {.inline.} =
  if s.keys.len * 2 >= s.buckets.len:
    s.grow()
  let
    mask = s.buckets.len - 1
    buckets = cast[ptr UncheckedArray[uint64]](addr s.buckets[0])
  var i = int(hashKey(key) shr s.shift)
  while true:
    let b = buckets[i]
    if (b and epochMask) != s.epoch:
      buckets[i] = s.epoch or uint64(s.keys.len + 1)
      s.keys.add key
      return
    if s.keys[int(b and indexMask) - 1] == key:
      return
    i = (i + 1) and mask

func find[K](s: TouchSet[K], key: K): int =
  if s.buckets.len == 0:
    return -1
  let mask = s.buckets.len - 1
  var i = int(hashKey(key) shr s.shift)
  while true:
    let b = s.buckets[i]
    if (b and epochMask) != s.epoch:
      return -1
    let idx = int(b and indexMask) - 1
    if s.keys[idx] == key:
      return idx
    i = (i + 1) and mask

proc init*(
    T: type BlockAccessListTrackerRef,
    ledger: ReadOnlyLedger,
    builder: ptr BlockAccessListBuilder = nil,
): T =
  let owned = builder.isNil()
  T(
    ledger: LedgerRef(ledger),
    builder: if owned: BlockAccessListBuilder.newShared() else: builder,
    builderOwner: owned,
    changes: BalChangesRef(),
  )

proc closeWindow(tracker: BlockAccessListTrackerRef) =
  if tracker.windowOpen:
    if tracker.ledger.balChanges == tracker.changes:
      tracker.ledger.balChanges = nil
    tracker.windowOpen = false
  tracker.changes[].clear()
  tracker.accounts.reset()
  tracker.slots.reset()

proc dispose*(tracker: BlockAccessListTrackerRef) =
  tracker.closeWindow()
  if tracker.builderOwner:
    assert not tracker.builder.isNil()
    tracker.builder.dispose()
    tracker.builder = nil
    tracker.builderOwner = false

proc reinit*(tracker: BlockAccessListTrackerRef, ledger: ReadOnlyLedger) =
  tracker.closeWindow()
  tracker.ledger = LedgerRef(ledger)
  tracker.currentBlockAccessIndex = 0
  tracker.blockAccessList = Opt.none(BlockAccessListRef)
  if tracker.builderOwner:
    tracker.builder[].clear()

proc setBlockAccessIndex*(tracker: BlockAccessListTrackerRef, blockAccessIndex: int) =
  tracker.closeWindow()
  tracker.currentBlockAccessIndex = blockAccessIndex
  tracker.builder[].ensureIndexCount(blockAccessIndex + 1)

proc beginCallFrame*(tracker: BlockAccessListTrackerRef) =
  doAssert not tracker.windowOpen
  doAssert tracker.ledger.isTopLevelClean()
  tracker.windowOpen = true
  tracker.ledger.balChanges = tracker.changes

proc emit(tracker: BlockAccessListTrackerRef) =
  let
    index = tracker.currentBlockAccessIndex
    builder = tracker.builder
    changes = tracker.changes
  for e in changes.balances:
    if e.pre != e.post:
      builder[].addBalanceChange(index, e.address, e.post)
  for e in changes.nonces:
    if e.pre != e.post:
      builder[].addNonceChange(index, e.address, e.post)
  for i, e in changes.codeDiffs:
    if e.pre != e.post:
      let code = changes.codes[i]
      if code.isNil():
        builder[].addCodeChange(index, e.address, [])
      else:
        builder[].addCodeChange(index, e.address, code.bytes())
  builder[].addTouchedAccounts(index, tracker.accounts.keys)
  if changes.slots.len == 0:
    builder[].addStorageReads(index, tracker.slots.keys)
    return
  tracker.writeOf.setLen(0)
  tracker.writeOf.setLen(tracker.slots.keys.len)
  for ci in 0 ..< changes.slots.len:
    template e(): untyped =
      changes.slots[ci]
    if e.pre != e.post:
      let i = tracker.slots.find((e.address, e.slot))
      if i >= 0:
        tracker.writeOf[i] = int32(ci + 1)
      else:
        builder[].addStorageWrite(index, e.address, e.slot, e.post)
  for i in 0 ..< tracker.slots.keys.len:
    let
      k = tracker.slots.keys[i]
      w = tracker.writeOf[i]
    if w == 0:
      builder[].addStorageRead(index, k.address, k.slot)
    else:
      builder[].addStorageWrite(index, k.address, k.slot, changes.slots[w - 1].post)

proc commitCallFrame*(tracker: BlockAccessListTrackerRef) =
  doAssert tracker.windowOpen
  if not tracker.ledger.isTopLevelClean():
    tracker.ledger.collectBalChanges()
  tracker.emit()
  tracker.closeWindow()

proc rollbackCallFrame*(tracker: BlockAccessListTrackerRef, rollbackReads = false) =
  doAssert tracker.windowOpen
  if not rollbackReads:
    tracker.emit()
  tracker.closeWindow()

proc trackAddressAccess*(tracker: BlockAccessListTrackerRef, address: Address) {.inline.} =
  assert tracker.windowOpen
  tracker.accounts.incl(address)

proc trackStorageRead*(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
) {.inline.} =
  assert tracker.windowOpen
  tracker.slots.incl((address, slot))

proc getBlockAccessList*(
    tracker: BlockAccessListTrackerRef, rebuild = false
): lent Opt[BlockAccessListRef] =
  if rebuild or tracker.blockAccessList.isNone():
    tracker.blockAccessList = Opt.some(tracker.builder[].buildBlockAccessList())

  tracker.blockAccessList

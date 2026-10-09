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
  eth/common/addresses,
  stint,
  ../db/ledger,
  ./[bal_access, bal_builder, bal_changes]

export addresses, bal_builder, ledger, stint

type
  BlockAccessListTrackerRef* = ref object
    ledger: LedgerRef
    builder*: ptr BlockAccessListBuilder
    builderOwner*: bool
    currentBlockAccessIndex*: int
    windowOpen: bool
    accounts: AccessSet[Address]
    slots: AccessSet[AccessedSlot]
    writeOf: seq[int32]
    changes: BalChangesRef
    blockAccessList: Opt[BlockAccessListRef]

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

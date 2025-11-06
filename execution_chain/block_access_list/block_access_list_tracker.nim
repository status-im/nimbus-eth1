# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets],
  eth/common/addresses,
  stint,
  ../db/ledger,
  ./block_access_list_builder

export addresses, block_access_list_builder, ledger, stint

type
  # Snapshot of block access list state for a single call frame.
  # Used to track changes within a call frame to enable proper handling
  # of reverts as specified in EIP-7928.
  CallFrameSnapshot = object # should this be a ref object?
    touchedAddresses: HashSet[Address]
      ## Set of addresses touched during this call frame.
    storageWrites: Table[(Address, UInt256), UInt256]
      ## Storage writes made during this call frame.
      ## Maps (address, storage key) -> storage value.
    balanceChanges: HashSet[(Address, int, UInt256)]
      ## Balance changes made during this call frame.
      ## Set of (address, block access index, balance)
    nonceChanges: HashSet[(Address, int, AccountNonce)]
      ## Nonce changes made during this call frame.
      ## Set of (address, block access index, nonce)
    codeChanges: HashSet[(Address, int, seq[byte])]
      ## Code changes made during this call frame.
      ## Set of (address, block access index, bytecode)

  # Tracks state changes during transaction execution for block access list
  # construction. This tracker maintains a cache of pre-state values and
  # coordinates with the BlockAccessListBuilder to record all state changes
  # made during block execution. It ensures that only actual changes (not no-op
  # writes) are recorded in the access list.
  StateChangeTrackerRef* = ref object
    ledger: ReadOnlyLedger
      ## Used to fetch the pre-transaction values from the state.
    builder: BlockAccessListBuilderRef
      ## The builder instance that accumulates all tracked changes.
    preStorageCache: Table[(Address, UInt256), UInt256]
      ## Cache of pre-transaction storage values, keyed by (address, slot) tuples.
      ## This cache is cleared at the start of each transaction to track values
      ## from the beginning of the current transaction.
    preBalanceCache: Table[Address, UInt256]
      ## Cache of pre-transaction balance values, keyed by address.
      ## This cache is cleared at the start of each transaction and used by
      ## normalize_balance_changes to filter out balance changes where
      ## the final balance equals the initial balance.
    currentBlockAccessIndex: int
      ## The current block access index (0 for pre-execution,
      ## 1..n for transactions, n+1 for post-execution).
    callFrameSnapshots: seq[CallFrameSnapshot]
      ## Stack of snapshots for nested call frames to handle reverts properly.

proc init*(T: type CallFrameSnapshot): T =
  CallFrameSnapshot()

# Disallow copying of CallFrameSnapshot
proc `=copy`(dest: var CallFrameSnapshot; src: CallFrameSnapshot) {.error: "Copying CallFrameSnapshot is forbidden".} =
  discard

proc init*(
    T: type StateChangeTrackerRef,
    ledger: ReadOnlyLedger,
    builder = BlockAccessListBuilderRef.init()): T =
  StateChangeTrackerRef(ledger: ledger, builder: builder)

proc setBlockAccessIndex*(tracker: StateChangeTrackerRef, blockAccessIndex: int) =
  doAssert blockAccessIndex > 0
  tracker.currentBlockAccessIndex = blockAccessIndex
  tracker.preStorageCache.clear()
  tracker.preBalanceCache.clear()

proc capturePreState*(tracker: StateChangeTrackerRef, address: Address, slot: UInt256): UInt256 =
  let cacheKey = (address, slot)

  if cacheKey notin tracker.preStorageCache:
    tracker.preStorageCache[cacheKey] = tracker.ledger.getStorage(address, slot)

  return tracker.preStorageCache.getOrDefault(cacheKey)

template trackAddressAccess*(tracker: StateChangeTrackerRef, address: Address) =
  tracker.builder.addTouchedAccount(address)

proc trackStorageRead*(tracker: StateChangeTrackerRef, address: Address, slot: UInt256) =
  tracker.trackAddressAccess(address)
  discard tracker.capturePreState(address, slot)
  tracker.builder.addStorageRead(address, slot)

proc trackStorageWrite*(tracker: StateChangeTrackerRef, address: Address, slot: UInt256, newValue: UInt256) =
  tracker.trackAddressAccess(address)

  let preValue = tracker.capturePreState(address, slot)
  if preValue != newValue:
    tracker.builder.addStorageWrite(
        address,
        slot,
        tracker.currentBlockAccessIndex,
        newValue)
    # Record in current call frame snapshot if exists
    if tracker.callFrameSnapshots.len() > 0:
      tracker.callFrameSnapshots[^1].storageWrites[(address, slot)] = newValue
  else:
    tracker.builder.addStorageRead(address, slot)

proc capturePreBalance*(tracker: StateChangeTrackerRef, address: Address): UInt256 =
  if address notin tracker.preBalanceCache:
    tracker.preBalanceCache[address] = tracker.ledger.getBalance(address)
  return tracker.preBalanceCache.getOrDefault(address)

proc trackBalanceChange*(tracker: StateChangeTrackerRef, address: Address, newBalance: UInt256) =
  tracker.trackAddressAccess(address)

  let blockAccessIndex = tracker.currentBlockAccessIndex
  tracker.builder.addBalanceChange(address, blockAccessIndex, newBalance)

  # Record in current call frame snapshot if exists
  if tracker.callFrameSnapshots.len() > 0:
    tracker.callFrameSnapshots[^1].balanceChanges.incl((address, blockAccessIndex, newBalance))

proc trackNonceChange*(tracker: StateChangeTrackerRef, address: Address, newNonce: AccountNonce) =
  tracker.trackAddressAccess(address)

  let blockAccessIndex = tracker.currentBlockAccessIndex
  tracker.builder.addNonceChange(address, blockAccessIndex, newNonce)

  # Record in current call frame snapshot if exists
  if tracker.callFrameSnapshots.len() > 0:
    tracker.callFrameSnapshots[^1].nonceChanges.incl((address, blockAccessIndex, newNonce))

proc trackCodeChange*(tracker: StateChangeTrackerRef, address: Address, newCode: seq[byte]) =
  tracker.trackAddressAccess(address)

  let blockAccessIndex = tracker.currentBlockAccessIndex
  tracker.builder.addCodeChange(address, blockAccessIndex, newCode)

  # Record in current call frame snapshot if exists
  if tracker.callFrameSnapshots.len() > 0:
    tracker.callFrameSnapshots[^1].codeChanges.incl((address, blockAccessIndex, newCode))

proc handleInTransactionSelfDestruct*(tracker: StateChangeTrackerRef, address: Address) =
  tracker.builder.accounts.withValue(address, accData):
    let currentIndex = tracker.currentBlockAccessIndex

    # Convert storage writes from current tx to reads
    var slotsToConvert: seq[UInt256]
    for slot, slotChanges in accData[].storageChanges.mpairs():
      slotChanges.del(currentIndex)
      if slotChanges.len() == 0:
        slotsToConvert.add(slot)

    for slot in slotsToConvert:
      accData[].storageChanges.del(slot)
      accData[].storageReads.incl(slot)

    # Remove nonce and code changes from current transaction
    accData[].nonceChanges.del(currentIndex)
    accData[].codeChanges.del(currentIndex)

proc normalizeBalanceChanges*(tracker: StateChangeTrackerRef) =
  let currentIndex = tracker.currentBlockAccessIndex

  # Check each address that had balance changes in this transaction
  for address, accData in tracker.builder.accounts.mpairs():
    let
      preBalance = tracker.capturePreBalance(address)
      postBalance = tracker.ledger.getBalance(address)

    # If pre-tx balance equals post-tx balance, remove all balance changes
    # for this address in the current transaction
    if preBalance == postBalance:
      # Filter out balance changes from the current transaction
      accData.balanceChanges.del(currentIndex)

proc beginCallFrame*(tracker: StateChangeTrackerRef) =
  tracker.callFrameSnapshots.add(CallFrameSnapshot.init())

proc rollbackCallFrame*(tracker: StateChangeTrackerRef) =
  doAssert tracker.callFrameSnapshots.len() > 0

  let
    currentIndex = tracker.currentBlockAccessIndex
    snapshot = tracker.callFrameSnapshots.pop()

  # Convert storage writes to reads
  for key in snapshot.storageWrites.keys():
    let (address, slot) = key

    tracker.builder.accounts.withValue(address, accData):
      accData[].storageChanges.withValue(slot, slotChanges):
        # Filter out changes from this call frame
        slotChanges[].del(currentIndex)
        if slotChanges[].len() == 0:
          accData[].storageChanges.del(slot)
          accData[].storageReads.incl(slot) # Add as a read instead

  # Remove balance changes from this call frame
  for change in snapshot.balanceChanges:
    let (address, blockAccessIndex, newBalance) = change

    tracker.builder.accounts.withValue(address, accData):
      # Filter out balance changes from this call frame
      accData[].balanceChanges.withValue(currentIndex, postBalance):
        if postBalance[] == newBalance:
          accData[].balanceChanges.del(currentIndex)

  # Remove nonce changes from this call frame
  for change in snapshot.nonceChanges:
    let (address, blockAccessIndex, newNonce) = change

    tracker.builder.accounts.withValue(address, accData):
      # Filter out nonce changes from this call frame
      accData[].nonceChanges.withValue(currentIndex, postNonce):
        if postNonce[] == newNonce:
          accData[].nonceChanges.del(currentIndex)

  # Remove code changes from this call frame
  for change in snapshot.codeChanges:
    let (address, blockAccessIndex, newCode) = change

    tracker.builder.accounts.withValue(address, accData):
      # Filter out nonce changes from this call frame
      accData[].codeChanges.withValue(currentIndex, postCode):
        if postCode[] == newCode:
          accData[].codeChanges.del(currentIndex)

  # All touched addresses remain in the access list (already tracked)

proc commitCallFrame*(tracker: StateChangeTrackerRef) =
  if tracker.callFrameSnapshots.len() > 0:
    discard tracker.callFrameSnapshots.pop()

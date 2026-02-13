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
  CallFrameSnapshot* = object
    touchedAddresses*: HashSet[Address]
      ## Addresses read during this call frame.
    storageReads*: HashSet[(Address, UInt256)]
      ## Storage reads made during this call frame.
    storageChanges*: Table[(Address, UInt256), UInt256]
      ## Storage writes made during this call frame.
      ## Maps (address, storage key) -> storage value.
    balanceChanges*: Table[Address, UInt256]
      ## Balance changes made during this call frame.
      ## Set of (address, block access index, balance)
      ## Maps address -> balance.
    nonceChanges*: Table[Address, AccountNonce]
      ## Nonce changes made during this call frame.
      ## Maps address -> nonce.
    codeChanges*: Table[Address, seq[byte]]
      ## Code changes made during this call frame.
      ## Maps address -> bytecode.
    inTransactionSelfDestructs*: HashSet[Address]
      ## Set of addresses which need to have writes removed (and in some cases
      ## also converted to reads) when commiting a call frame.


  # Tracks state changes during transaction execution for block access list
  # construction. This tracker maintains a cache of pre-state values and
  # coordinates with the BlockAccessListBuilder to record all state changes
  # made during block execution. It ensures that only actual changes (not no-op
  # writes) are recorded in the access list.
  BlockAccessListTrackerRef* = ref object
    ledger*: ReadOnlyLedger
      ## Used to fetch the pre-transaction values from the state.
    builder*: ConcurrentBlockAccessListBuilderRef
      ## The builder instance that accumulates all tracked changes.
    preStorageCache*: Table[(Address, UInt256), UInt256]
      ## Cache of pre-transaction storage values, keyed by (address, slot) tuples.
      ## This cache is cleared at the start of each transaction to track values
      ## from the beginning of the current transaction.
    preBalanceCache*: Table[Address, UInt256]
      ## Cache of pre-transaction balance values, keyed by address.
      ## This cache is cleared at the start of each transaction and used by
      ## normalize_balance_changes to filter out balance changes where
      ## the final balance equals the initial balance.
    preNonceCache*: Table[Address, AccountNonce]
      ## Cache of pre-transaction nonce values, keyed by address.
      ## This cache is cleared at the start of each transaction to track values
      ## from the beginning of the current transaction.
    preCodeCache*: Table[Address, seq[byte]]
      ## Cache of pre-transaction code, keyed by address.
      ## This cache is cleared at the start of each transaction to track values
      ## from the beginning of the current transaction.
    currentBlockAccessIndex*: int
      ## The current block access index (0 for pre-execution,
      ## 1..n for transactions, n+1 for post-execution).
    callFrameSnapshots*: seq[CallFrameSnapshot]
      ## Stack of snapshots for nested call frames to handle reverts properly.
    blockAccessList: Opt[BlockAccessListRef]
      ## Created by the builder and cached for reuse.


template init(T: type CallFrameSnapshot): T =
  CallFrameSnapshot()

# Disallow copying of CallFrameSnapshot
proc `=copy`(dest: var CallFrameSnapshot; src: CallFrameSnapshot) {.error: "Copying CallFrameSnapshot is forbidden".} =
  discard

proc init*(
    T: type BlockAccessListTrackerRef,
    ledger: ReadOnlyLedger,
    builder = ConcurrentBlockAccessListBuilderRef.init()): T =
  BlockAccessListTrackerRef(ledger: ledger, builder: builder)

proc setBlockAccessIndex*(tracker: BlockAccessListTrackerRef, blockAccessIndex: int) =
  ## Must be called before processing each transaction/system contract
  ## to ensure changes are associated with the correct block access index.
  ## Note: Block access indices differ from transaction indices:
  ##   - 0: Pre-execution (system contracts like beacon roots, block hashes)
  ##   - 1..n: Transactions (tx at index i gets block_access_index i+1)
  ##   - n+1: Post-execution (withdrawals, requests)
  doAssert blockAccessIndex >= int(uint16.low) and blockAccessIndex <= int(uint16.high)

  tracker.preStorageCache.clear()
  tracker.preBalanceCache.clear()
  tracker.preNonceCache.clear()
  tracker.preCodeCache.clear()
  tracker.currentBlockAccessIndex = blockAccessIndex

template hasPendingCallFrame*(tracker: BlockAccessListTrackerRef): bool =
  tracker.callFrameSnapshots.len() > 0

template hasParentCallFrame*(tracker: BlockAccessListTrackerRef): bool =
  tracker.callFrameSnapshots.len() > 1

template pendingCallFrame*(tracker: BlockAccessListTrackerRef): CallFrameSnapshot =
  tracker.callFrameSnapshots[tracker.callFrameSnapshots.high]

template parentCallFrame*(tracker: BlockAccessListTrackerRef): CallFrameSnapshot =
  tracker.callFrameSnapshots[tracker.callFrameSnapshots.high - 1]

template beginCallFrame*(tracker: BlockAccessListTrackerRef) =

  ## Begin a new call frame for tracking reverts.
  ## Creates a new snapshot to track changes within this call frame.
  ## This allows proper handling of reverts as specified in EIP-7928.
  tracker.callFrameSnapshots.add(CallFrameSnapshot.init())

template popCallFrame(tracker: BlockAccessListTrackerRef) =
  tracker.callFrameSnapshots.setLen(tracker.callFrameSnapshots.len() - 1)

proc handleInTransactionSelfDestruct*(tracker: BlockAccessListTrackerRef, address: Address)
proc normalizePendingCallFrameChanges*(tracker: BlockAccessListTrackerRef)

proc commitCallFrame*(tracker: BlockAccessListTrackerRef) =
  # Commit changes from the current call frame.
  # Removes the current call frame snapshot without rolling back changes.
  # Called when a call completes successfully.
  doAssert tracker.hasPendingCallFrame()

  if tracker.hasParentCallFrame():
    # Merge the pending call frame writes into the parent

    for address in tracker.pendingCallFrame.inTransactionSelfDestructs:
      tracker.handleInTransactionSelfDestruct(address)
      tracker.parentCallFrame.inTransactionSelfDestructs.incl(address)

    for storageKey, newValue in tracker.pendingCallFrame.storageChanges:
      tracker.parentCallFrame.storageChanges[storageKey] = newValue

    for address, newBalance in tracker.pendingCallFrame.balanceChanges:
      tracker.parentCallFrame.balanceChanges[address] = newBalance

    for address, newNonce in tracker.pendingCallFrame.nonceChanges:
      tracker.parentCallFrame.nonceChanges[address] = newNonce

    for address, newCode in tracker.pendingCallFrame.codeChanges:
      tracker.parentCallFrame.codeChanges[address] = newCode

    # Merge the pending call frame reads into the parent
    tracker.parentCallFrame.touchedAddresses.incl(tracker.pendingCallFrame.touchedAddresses)
    tracker.parentCallFrame.storageReads.incl(tracker.pendingCallFrame.storageReads)

  else:
    # Merge the pending call frame writes into the builder

    for address in tracker.pendingCallFrame.inTransactionSelfDestructs:
      tracker.handleInTransactionSelfDestruct(address)

    tracker.normalizePendingCallFrameChanges()

    let currentIndex = tracker.currentBlockAccessIndex

    for storageKey, newValue in tracker.pendingCallFrame.storageChanges:
      let (address, slot) = storageKey
      tracker.builder.addStorageWrite(address, slot, currentIndex, newValue)

    for address, newBalance in tracker.pendingCallFrame.balanceChanges:
      tracker.builder.addBalanceChange(address, currentIndex, newBalance)

    for address, newNonce in tracker.pendingCallFrame.nonceChanges:
      tracker.builder.addNonceChange(address, currentIndex, newNonce)

    for address, newCode in tracker.pendingCallFrame.codeChanges:
      tracker.builder.addCodeChange(address, currentIndex, newCode)

    # Merge the pending call frame reads into the builder
    for address in tracker.pendingCallFrame.touchedAddresses:
      tracker.builder.addTouchedAccount(address)
    for storageKey in tracker.pendingCallFrame.storageReads:
      tracker.builder.addStorageRead(storageKey[0], storageKey[1])

  tracker.popCallFrame()

proc rollbackCallFrame*(tracker: BlockAccessListTrackerRef, rollbackReads = false) =
  ## Rollback changes from the current call frame.
  ## When a call reverts, this function:
  ## - Converts storage writes to reads
  ## - Preserves touched addresses
  ## This implements EIP-7928 revert handling where reverted writes
  ## become reads and addresses remain in the access list.
  doAssert tracker.hasPendingCallFrame()

  if rollbackReads:
    tracker.popCallFrame()
    return # discard all changes


  if tracker.hasParentCallFrame():
    # Merge the pending call frame reads into the parent
    tracker.parentCallFrame.touchedAddresses.incl(tracker.pendingCallFrame.touchedAddresses)
    tracker.parentCallFrame.storageReads.incl(tracker.pendingCallFrame.storageReads)

    # Convert storage writes to reads
    for storageKey in tracker.pendingCallFrame.storageChanges.keys():
      tracker.parentCallFrame.storageReads.incl(storageKey)
  else:
    # Merge the pending call frame reads into the builder
    for address in tracker.pendingCallFrame.touchedAddresses:
      tracker.builder.addTouchedAccount(address)
    for storageKey in tracker.pendingCallFrame.storageReads:
      tracker.builder.addStorageRead(storageKey[0], storageKey[1])

    # Convert storage writes to reads
    for storageKey in tracker.pendingCallFrame.storageChanges.keys():
      tracker.builder.addStorageRead(storageKey[0], storageKey[1])

  tracker.popCallFrame()

proc capturePreBalance*(tracker: BlockAccessListTrackerRef, address: Address) =
  ## Capture and cache the pre-transaction balance for an account.
  ## This function caches the balance on first access for each address during
  ## a transaction. It must be called before any balance modifications are made
  ## to ensure we capture the pre-transaction balance correctly. The cache is
  ## cleared at the beginning of each transaction.
  ## This is used by normalize_balance_changes to determine which balance
  ## changes should be filtered out.
  if address notin tracker.preBalanceCache:
    tracker.preBalanceCache[address] = tracker.ledger.getBalance(address)

template getPreBalance*(tracker: BlockAccessListTrackerRef, address: Address): UInt256 =
  tracker.preBalanceCache.getOrDefault(address)

proc capturePreNonce*(tracker: BlockAccessListTrackerRef, address: Address) =
  if address notin tracker.preNonceCache:
    tracker.preNonceCache[address] = tracker.ledger.getNonce(address)

template getPreNonce*(tracker: BlockAccessListTrackerRef, address: Address): AccountNonce =
  tracker.preNonceCache.getOrDefault(address)

proc capturePreCode*(tracker: BlockAccessListTrackerRef, address: Address) =
  if address notin tracker.preCodeCache:
    tracker.preCodeCache[address] = tracker.ledger.getCode(address).bytes

template getPreCode*(tracker: BlockAccessListTrackerRef, address: Address): seq[byte] =
  tracker.preCodeCache.getOrDefault(address)

proc capturePreStorage*(tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256) =
  ## Capture and cache the pre-transaction value for a storage location.
  ## Retrieves the storage value from the beginning of the current transaction.
  ## The value is cached within the transaction to avoid repeated lookups and
  ## to maintain consistency across multiple accesses within the same
  ## transaction.
  let storageKey = (address, slot)

  if storageKey notin tracker.preStorageCache:
    tracker.preStorageCache[storageKey] = tracker.ledger.getStorage(address, slot)

template getPreStorage*(tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256): UInt256 =
  tracker.preStorageCache.getOrDefault((address, slot))

template trackAddressAccess*(tracker: BlockAccessListTrackerRef, address: Address) =
  ## Track that an address was accessed.
  ## Records account access even when no state changes occur. This is
  ## important for operations that read account data without modifying it.
  assert tracker.hasPendingCallFrame()
  tracker.pendingCallFrame.touchedAddresses.incl(address)

proc trackStorageRead*(tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256) =
  ## Track a storage read operation.
  ## Records that a storage slot was read and captures its pre-state value.
  ## The slot will only appear in the final access list if it wasn't also
  ## written to during block execution.
  assert tracker.hasPendingCallFrame()
  tracker.pendingCallFrame.touchedAddresses.incl(address)
  tracker.pendingCallFrame.storageReads.incl((address, slot))

proc trackStorageWrite*(tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256, newValue: UInt256) =
  ## Track a storage write operation.
  ## Records storage modifications, but only if the new value differs from
  ## the pre-state value. No-op writes (where the value doesn't change) are
  ## tracked as reads instead, as specified in [EIP-7928].
  assert tracker.hasPendingCallFrame()

  let storageKey = (address, slot)
  tracker.pendingCallFrame.storageChanges.withValue(storageKey, value):
    if newValue == value[]:
      return # nothing to do because we have already tracked this value

  tracker.trackAddressAccess(address)
  tracker.capturePreStorage(address, slot)
  tracker.pendingCallFrame.storageChanges[storageKey] = newValue

proc trackBalanceChange*(tracker: BlockAccessListTrackerRef, address: Address, newBalance: UInt256) =
  ## Track a balance change for an account.
  ## Records the new balance after any balance-affecting operation, including
  ## transfers, gas payments, block rewards, and withdrawals.
  assert tracker.hasPendingCallFrame()

  tracker.pendingCallFrame.balanceChanges.withValue(address, balance):
    if newBalance == balance[]:
      return # nothing to do because we have already tracked this value

  tracker.trackAddressAccess(address)
  tracker.capturePreBalance(address)
  tracker.pendingCallFrame.balanceChanges[address] = newBalance

proc trackAddBalanceChange*(tracker: BlockAccessListTrackerRef, address: Address, delta: UInt256) =
  if delta.isZero:
    tracker.trackAddressAccess(address)
    return

  tracker.trackBalanceChange(address, tracker.ledger.getBalance(address) + delta)

proc trackSubBalanceChange*(tracker: BlockAccessListTrackerRef, address: Address, delta: UInt256) =
  if delta.isZero:
    # In this case we don't call trackAddressAccess because the account isn't read
    # due to early return as defined in EIP-4788
    return

  tracker.trackBalanceChange(address, tracker.ledger.getBalance(address) - delta)

proc trackNonceChange*(tracker: BlockAccessListTrackerRef, address: Address, newNonce: AccountNonce) =
  ## Track a nonce change for an account.
  ## Records nonce increments for both EOAs (when sending transactions) and
  ## contracts (when performing [`CREATE`] or [`CREATE2`] operations). Deployed
  ## contracts also have their initial nonce tracked.
  assert tracker.hasPendingCallFrame()

  tracker.pendingCallFrame.nonceChanges.withValue(address, nonce):
    if newNonce == nonce[]:
      return # nothing to do because we have already tracked this value

  tracker.trackAddressAccess(address)
  tracker.capturePreNonce(address)
  tracker.pendingCallFrame.nonceChanges[address] = newNonce

template trackIncNonceChange*(tracker: BlockAccessListTrackerRef, address: Address) =
  tracker.trackNonceChange(address, tracker.ledger.getNonce(address) + 1)

proc trackCodeChange*(tracker: BlockAccessListTrackerRef, address: Address, newCode: seq[byte]) =
  ## Track a code change for contract deployment.
  ## Records new contract code deployments via [`CREATE`], [`CREATE2`], or
  ## [`SETCODE`] operations. This function is called when contract bytecode
  ## is deployed to an address.
  assert tracker.hasPendingCallFrame()

  tracker.pendingCallFrame.codeChanges.withValue(address, code):
    if newCode == code[]:
      return # nothing to do because we have already tracked this value

  tracker.trackAddressAccess(address)
  tracker.capturePreCode(address)
  tracker.pendingCallFrame.codeChanges[address] = newCode

proc trackSelfDestruct*(tracker: BlockAccessListTrackerRef, address: Address) =
  tracker.trackBalanceChange(address, 0.u256)

proc trackInTransactionSelfDestruct*(tracker: BlockAccessListTrackerRef, address: Address) =
  assert tracker.hasPendingCallFrame()
  tracker.pendingCallFrame.inTransactionSelfDestructs.incl(address)

proc handleInTransactionSelfDestruct*(tracker: BlockAccessListTrackerRef, address: Address) =
  ## Handle an account that self-destructed in the same transaction it was
  ## created.
  ## Per EIP-7928, accounts destroyed within their creation transaction must be
  ## included as read-only with storage writes converted to reads. Nonce and
  ## code changes from the current transaction are also removed.
  assert tracker.hasPendingCallFrame()

  var slotsToConvert: seq[UInt256]
  for storageKey in tracker.pendingCallFrame.storageChanges.keys():
    let (adr, slot) = storageKey
    if adr == address:
      slotsToConvert.add(slot)

  for slot in slotsToConvert:
    let storageKey = (address, slot)
    tracker.pendingCallFrame.storageReads.incl(storageKey)
    tracker.pendingCallFrame.storageChanges.del(storageKey)

  tracker.pendingCallFrame.balanceChanges.del(address)
  tracker.pendingCallFrame.nonceChanges.del(address)
  tracker.pendingCallFrame.codeChanges.del(address)

  tracker.trackBalanceChange(address, 0.u256)

proc normalizePendingCallFrameChanges*(tracker: BlockAccessListTrackerRef) =
  ## Normalize balance, nonce, code and storage changes for the current
  ## block access index.
  ## This method filters out spurious balance and storage changes by removing all
  ## changes for addresses and slots where the post-execution balance/value equals
  ## the pre-execution/value balance.
  ## This is crucial for handling cases like:
  ## - In-transaction self-destructs where an account with 0 balance is created
  ##   and destroyed, resulting in no net balance change
  ## - Round-trip transfers where an account receives and sends equal amounts
  ## - Zero-amount withdrawals where the balance doesn't actually change
  ## - Storage no-op writes
  ## This should be called at the end of any operation that tracks balance
  ## changes (transactions, withdrawals, etc.). Only actual state changes are
  ## recorded in the Block Access List.
  assert tracker.hasPendingCallFrame()

  var slotsToRemove: seq[(Address, UInt256)]
  for storageKey, postValue in tracker.pendingCallFrame.storageChanges:
    let
      (address, slot) = storageKey
      preValue = tracker.getPreStorage(address, slot)
    if preValue == postValue:
      slotsToRemove.add(storageKey)

  for storageKey in slotsToRemove:
    tracker.pendingCallFrame.storageReads.incl(storageKey)
    tracker.pendingCallFrame.storageChanges.del(storageKey)

  block:
    var addressesToRemove: seq[Address]
    for address, postBalance in tracker.pendingCallFrame.balanceChanges:
      let preBalance = tracker.getPreBalance(address)
      if preBalance == postBalance:
        addressesToRemove.add(address)

    for address in addressesToRemove:
      tracker.pendingCallFrame.balanceChanges.del(address)

  block:
    var addressesToRemove: seq[Address]
    for address, newNonce in tracker.pendingCallFrame.nonceChanges:
      let preNonce = tracker.getPreNonce(address)
      if preNonce == newNonce:
        addressesToRemove.add(address)

    for address in addressesToRemove:
      tracker.pendingCallFrame.nonceChanges.del(address)

  block:
    var addressesToRemove: seq[Address]
    for address, newCode in tracker.pendingCallFrame.codeChanges:
      let preCode = tracker.getPreCode(address)
      if preCode == newCode:
        addressesToRemove.add(address)

    for address in addressesToRemove:
      tracker.pendingCallFrame.codeChanges.del(address)

proc getBlockAccessList*(tracker: BlockAccessListTrackerRef, rebuild = false): lent Opt[BlockAccessListRef] =
  if rebuild or tracker.blockAccessList.isNone():
    tracker.blockAccessList = Opt.some(tracker.builder.buildBlockAccessList())

  tracker.blockAccessList

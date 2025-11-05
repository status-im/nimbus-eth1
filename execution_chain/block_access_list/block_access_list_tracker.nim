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
  if address notin tracker.builder.accounts:
    return

  let currentIndex = tracker.currentBlockAccessIndex

  tracker.builder.accounts.withValue(address, accData):

    # # Convert storage writes from current tx to reads
    # for slot in accountData.storageChanges.keys():
    #   account_data.storage_changes[slot] = [
    #       c
    #       for c in account_data.storage_changes[slot]
    #       if c.block_access_index != current_index
    #   ]
    #   if not account_data.storage_changes[slot]:
    #       del account_data.storage_changes[slot]
    #       account_data.storage_reads.add(slot)

    # Remove nonce and code changes from current transaction
    accData[].nonceChanges.del(currentIndex)
    accData[].codeChanges.del(currentIndex)

proc normalizeBalanceChanges*(tracker: StateChangeTrackerRef) =
  # TODO
  discard

proc beginCallFrame*(tracker: StateChangeTrackerRef) =
  tracker.callFrameSnapshots.add(CallFrameSnapshot.init())

proc rollbackCallFrame*(tracker: StateChangeTrackerRef) =
  # TODO
  discard

proc commitCallFrame*(tracker: StateChangeTrackerRef) =
  if tracker.callFrameSnapshots.len() > 0:
    discard tracker.callFrameSnapshots.pop()



# def handle_in_transaction_selfdestruct(
#     tracker: StateChangeTracker, address: Address
# ) -> None:
#     """
#     Handle an account that self-destructed in the same transaction it was
#     created.
#     Per EIP-7928, accounts destroyed within their creation transaction must be
#     included as read-only with storage writes converted to reads. Nonce and
#     code changes from the current transaction are also removed.
#     Note: Balance changes are handled separately by
#           normalize_balance_changes.
#     Parameters
#     ----------
#     tracker :
#         The state change tracker instance.
#     address :
#         The address that self-destructed.
#     """
#     builder = tracker.block_access_list_builder
#     if address not in builder.accounts:
#         return

#     account_data = builder.accounts[address]
#     current_index = tracker.current_block_access_index

#     # Convert storage writes from current tx to reads
#     for slot in list(account_data.storage_changes.keys()):
#         account_data.storage_changes[slot] = [
#             c
#             for c in account_data.storage_changes[slot]
#             if c.block_access_index != current_index
#         ]
#         if not account_data.storage_changes[slot]:
#             del account_data.storage_changes[slot]
#             account_data.storage_reads.add(slot)

#     # Remove nonce and code changes from current transaction
#     account_data.nonce_changes = [
#         c
#         for c in account_data.nonce_changes
#         if c.block_access_index != current_index
#     ]
#     account_data.code_changes = [
#         c
#         for c in account_data.code_changes
#         if c.block_access_index != current_index
#     ]


# def normalize_balance_changes(
#     tracker: StateChangeTracker, state: "State"
# ) -> None:
#     """
#     Normalize balance changes for the current block access index.
#     This method filters out spurious balance changes by removing all balance
#     changes for addresses where the post-execution balance equals the
#     pre-execution balance.
#     This is crucial for handling cases like:
#     - In-transaction self-destructs where an account with 0 balance is created
#       and destroyed, resulting in no net balance change
#     - Round-trip transfers where an account receives and sends equal amounts
#     - Zero-amount withdrawals where the balance doesn't actually change
#     This should be called at the end of any operation that tracks balance
#     changes (transactions, withdrawals, etc.). Only actual state changes are
#     recorded in the Block Access List.
#     Parameters
#     ----------
#     tracker :
#         The state change tracker instance.
#     state :
#         The current execution state.
#     """
#     # Import locally to avoid circular import
#     from ..state import get_account

#     builder = tracker.block_access_list_builder
#     current_index = tracker.current_block_access_index

#     # Check each address that had balance changes in this transaction
#     for address in list(builder.accounts.keys()):
#         account_data = builder.accounts[address]

#         # Get the pre-transaction balance
#         pre_balance = capture_pre_balance(tracker, address, state)

#         # Get the current (post-transaction) balance
#         post_balance = get_account(state, address).balance

#         # If pre-tx balance equals post-tx balance, remove all balance changes
#         # for this address in the current transaction
#         if pre_balance == post_balance:
#             # Filter out balance changes from the current transaction
#             account_data.balance_changes = [
#                 change
#                 for change in account_data.balance_changes
#                 if change.block_access_index != current_index
#             ]



# def rollback_call_frame(tracker: StateChangeTracker) -> None:
#     """
#     Rollback changes from the current call frame.
#     When a call reverts, this function:
#     - Converts storage writes to reads
#     - Removes balance, nonce, and code changes
#     - Preserves touched addresses
#     This implements EIP-7928 revert handling where reverted writes
#     become reads and addresses remain in the access list.
#     Parameters
#     ----------
#     tracker :
#         The state change tracker instance.
#     """
#     if not tracker.call_frame_snapshots:
#         return

#     snapshot = tracker.call_frame_snapshots.pop()
#     builder = tracker.block_access_list_builder

#     # Convert storage writes to reads
#     for (address, slot), _ in snapshot.storage_writes.items():
#         # Remove the write from storage_changes
#         if address in builder.accounts:
#             account_data = builder.accounts[address]
#             if slot in account_data.storage_changes:
#                 # Filter out changes from this call frame
#                 account_data.storage_changes[slot] = [
#                     change
#                     for change in account_data.storage_changes[slot]
#                     if change.block_access_index
#                     != tracker.current_block_access_index
#                 ]
#                 if not account_data.storage_changes[slot]:
#                     del account_data.storage_changes[slot]
#             # Add as a read instead
#             account_data.storage_reads.add(slot)

#     # Remove balance changes from this call frame
#     for address, block_access_index, new_balance in snapshot.balance_changes:
#         if address in builder.accounts:
#             account_data = builder.accounts[address]
#             # Filter out balance changes from this call frame
#             account_data.balance_changes = [
#                 change
#                 for change in account_data.balance_changes
#                 if not (
#                     change.block_access_index == block_access_index
#                     and change.post_balance == new_balance
#                 )
#             ]

#     # Remove nonce changes from this call frame
#     for address, block_access_index, new_nonce in snapshot.nonce_changes:
#         if address in builder.accounts:
#             account_data = builder.accounts[address]
#             # Filter out nonce changes from this call frame
#             account_data.nonce_changes = [
#                 change
#                 for change in account_data.nonce_changes
#                 if not (
#                     change.block_access_index == block_access_index
#                     and change.new_nonce == new_nonce
#                 )
#             ]

#     # Remove code changes from this call frame
#     for address, block_access_index, new_code in snapshot.code_changes:
#         if address in builder.accounts:
#             account_data = builder.accounts[address]
#             # Filter out code changes from this call frame
#             account_data.code_changes = [
#                 change
#                 for change in account_data.code_changes
#                 if not (
#                     change.block_access_index == block_access_index
#                     and change.new_code == new_code
#                 )
#             ]

#     # All touched addresses remain in the access list (already tracked)

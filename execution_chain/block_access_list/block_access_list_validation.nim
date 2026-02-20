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
  std/[sets, algorithm],
  eth/common/[block_access_lists, block_access_lists_rlp, hashes],
  stint,
  results,
  ../constants,
  ./block_access_list_utils

export block_access_lists, hashes, results

# The block access list is constrained by the block gas limit rather than a fixed
# maximum number of items. The constraint is defined as:
#
# bal_items <= block_gas_limit // ITEM_COST
#
# Where:
# - bal_items = addresses + storage_keys
# - ITEM_COST = 2000

const BAL_ITEM_COST = 2000.GasInt

func checkBalSize(
    bal: BlockAccessListRef, blockGasLimit: GasInt
): Result[void, string] =
  let addressCount = bal[].len()

  var storageKeysCount = 0
  for accChanges in bal[]:
    storageKeysCount += accChanges.storageChanges.len()
    storageKeysCount += accChanges.storageReads.len()

  let balItemCount = addressCount + storageKeysCount

  if balItemCount.GasInt <= blockGasLimit div BAL_ITEM_COST:
    ok()
  else:
    err("BAL exceeds max items cap")

func validate*(
    bal: BlockAccessListRef,
    expectedHash: Hash32,
    blockGasLimit: GasInt = DEFAULT_GAS_LIMIT,
): Result[void, string] =
  ## Validate that a block access list is structurally correct and matches the expected hash.

  # Check the size of the BAL to protect against DOS attacks
  ?bal.checkBalSize(blockGasLimit)

  # Validate ordering (addresses should be sorted lexicographically).
  if not bal[].isSorted(accChangesCmp):
    return err("Addresses should be sorted lexicographically")

  # Validate ordering of fields for each account
  for accountChanges in bal[]:
    # Validate storage changes slots are sorted lexicographically
    if not accountChanges.storageChanges.isSorted(slotChangesCmp):
      return err("Storage changes slots should be sorted lexicographically")

    # Check storage changes are sorted by blockAccessIndex
    var changedSlots: HashSet[StorageKey]
    for slotChanges in accountChanges.storageChanges:
      changedSlots.incl(slotChanges.slot)
      if not slotChanges.changes.isSorted(balIndexCmp):
        return err("Slot changes should be sorted by blockAccessIndex")

    # Check that storage changes and reads don't overlap for the same slot.
    for slot in accountChanges.storageReads:
      if changedSlots.contains(slot):
        return err("A slot should not be in both changes and reads")

    # Validate storage reads are sorted lexicographically
    if not accountChanges.storageReads.isSorted():
      return err("Storage reads should be sorted lexicographically")

    # Check balance changes are sorted by blockAccessIndex
    if not accountChanges.balanceChanges.isSorted(balIndexCmp):
      return err("Balance changes should be sorted by blockAccessIndex")

    # Check nonce changes are sorted by blockAccessIndex
    if not accountChanges.nonceChanges.isSorted(balIndexCmp):
      return err("Nonce changes should be sorted by blockAccessIndex")

    # Check code changes are sorted by blockAccessIndex
    if not accountChanges.codeChanges.isSorted(balIndexCmp):
      return err("Code changes should be sorted by blockAccessIndex")

  # Check that the block access list matches the expected hash.
  if bal[].computeBlockAccessListHash() != expectedHash:
    return err("Computed block access list hash does not match the expected hash")

  ok()

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
  # We assume there are no duplicate addresses, storageChanges or storageReads
  # when doing this size check. If there are duplicates then the duplicated
  # values would simply increase the item count and fail the size check earlier.
  # This is fine because BALs with duplicates will get rejected in the other
  # validations anyway.

  let addressCount = bal[].len()

  var storageKeysCount = 0
  for changes in bal[]:
    storageKeysCount += changes.storageChanges.len() + changes.storageReads.len()

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
  ## Validate that a block access list is structurally correct and matches the
  ## expected hash.

  # Check the size of the BAL to protect against DOS attacks. Do this first
  # because it is more efficient than the rest of the validations below.
  # TODO: enable this once the tests have been updated
  #?bal.checkBalSize(blockGasLimit)

  # The custom cmpTreatEqualAsGreater compare functions below enable validating
  # that each list contains no duplicates in each call to isSorted.

  # Validate addresses
  if not bal[].isSorted(accChangesCmpTreatEqualAsGreater):
    return err("Addresses should be unique and sorted lexicographically")

  # Validate fields for each account
  for accountChanges in bal[]:
    # Validate storage changes
    if not accountChanges.storageChanges.isSorted(slotChangesCmpTreatEqualAsGreater):
      return err("Storage changes slots should be unique and sorted lexicographically")

    # Check storage changes
    var changedSlots: HashSet[StorageKey]
    for slotChanges in accountChanges.storageChanges:
      changedSlots.incl(slotChanges.slot)
      if not slotChanges.changes.isSorted(balIndexCmpTreatEqualAsGreater):
        return err("Slot changes should be unique and sorted by blockAccessIndex")

    # Check that storage changes and reads don't overlap for the same slot.
    for slot in accountChanges.storageReads:
      if changedSlots.contains(slot):
        return err("A slot should not be in both changes and reads")

    # Validate storage reads
    if not accountChanges.storageReads.isSorted(storageKeyCmpTreatEqualAsGreater):
      return err("Storage reads should be unique and sorted lexicographically")

    # Check balance changes
    if not accountChanges.balanceChanges.isSorted(balIndexCmpTreatEqualAsGreater):
      return err("Balance changes should be unique and sorted by blockAccessIndex")

    # Check nonce changes
    if not accountChanges.nonceChanges.isSorted(balIndexCmpTreatEqualAsGreater):
      return err("Nonce changes should be unique and sorted by blockAccessIndex")

    # Check code changes
    if not accountChanges.codeChanges.isSorted(balIndexCmpTreatEqualAsGreater):
      return err("Code changes should be unique and sorted by blockAccessIndex")

  # Check that the block access list matches the expected hash.
  if bal[].computeBlockAccessListHash() != expectedHash:
    return err("Computed block access list hash does not match the expected hash")

  ok()

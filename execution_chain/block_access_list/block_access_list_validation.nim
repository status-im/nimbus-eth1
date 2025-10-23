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
  std/[sets, sequtils, algorithm],
  eth/common/[block_access_lists, block_access_lists_rlp, hashes],
  stint,
  stew/byteutils,
  results

export block_access_lists, hashes, results

# TODO: Consider setting max values and adding to the validation.
# This is not yet defined in the EIP.
# MAX_TXS = 30_000
# MAX_SLOTS = 300_000
# MAX_ACCOUNTS = 300_000
# MAX_CODE_SIZE = 24_576
# MAX_CODE_CHANGES = 1

func validate*(bal: BlockAccessList, expectedHash: Hash32): Result[void, string] =
  ## Validate that a block access list is structurally correct and matches the expected hash.

  # Check that storage changes and reads don't overlap for the same slot.
  for accountChanges in bal:
    var changedSlots: HashSet[StorageKey]

    for slotChanges in accountChanges.storageChanges:
      changedSlots.incl(slotChanges.slot)

    for slot in accountChanges.storageReads:
      if changedSlots.contains(slot):
        return err("A slot should not be in both changes and reads")

  # Validate ordering (addresses should be sorted lexicographically).
  let balAddresses = bal.mapIt(it.address.data.toHex())
  if balAddresses != balAddresses.sorted():
    return err("Addresses should be sorted lexicographically")

  # Validate ordering of fields for each account
  for accountChanges in bal:
    # Validate storage changes slots are sorted lexicographically
    let storageChangesSlots = accountChanges.storageChanges.mapIt(
        UInt256.fromBytesBE(it.slot.data))
    if storageChangesSlots != storageChangesSlots.sorted():
      return err("Storage changes slots should be sorted lexicographically")

    # Check storage changes are sorted by blockAccessIndex
    for slotChanges in accountChanges.storageChanges:
      let indices = slotChanges.changes.mapIt(it.blockAccessIndex)
      if indices != indices.sorted():
        return err("Slot changes should be sorted by blockAccessIndex")

    # Validate storage reads are sorted within each account
    let storageReadsSlots = accountChanges.storageReads.mapIt(
        UInt256.fromBytesBE(it.data))
    if storageReadsSlots != storageReadsSlots.sorted():
      return err("Storage reads should be sorted by blockAccessIndex")

    # Check balance changes are sorted by blockAccessIndex
    let balanceIndices = accountChanges.balanceChanges.mapIt(it.blockAccessIndex)
    if balanceIndices != balanceIndices.sorted():
      return err("Balance changes should be sorted by blockAccessIndex")

    # Check nonce changes are sorted by blockAccessIndex
    let nonceIndices = accountChanges.nonceChanges.mapIt(it.blockAccessIndex)
    if nonceIndices != nonceIndices.sorted():
      return err("Nonce changes should be sorted by blockAccessIndex")

    # Check code changes are sorted by blockAccessIndex
    let codeIndices = accountChanges.codeChanges.mapIt(it.blockAccessIndex)
    if codeIndices != codeIndices.sorted():
      return err("Code changes should be sorted by blockAccessIndex")

    # Check that the block access list matches the expected hash.
    if bal.computeBlockAccessListHash() != expectedHash:
      return err("Computed block access list hash does not match the expected hash")

  ok()

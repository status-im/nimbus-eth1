# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/algorithm,
  results,
  eth/common/[addresses, block_access_lists, headers],
  stew/byteutils

const
  SLOTS_PER_EPOCH* = 32'u64
    ## Consensus layer slots per epoch.

  BAL_RETENTION_EPOCHS* = 3533'u64
    ## EIP-7928: execution clients are only required to retain block access
    ## lists for (at least) the last 3533 epochs.

func isWithinBalRetentionPeriod*(header: Header, headSlot: uint64): bool =
  ## Whether the block access list (EIP-7928) for `header` must still be retained
  ## by an execution client, i.e. the block falls within the last
  ## `BAL_RETENTION_EPOCHS` epochs relative to `currentSlot` (typically the slot
  ## of the chain head).
  
  # Blocks before Amsterdam carry no slot number (and no block access list)
  let blockSlot = header.slotNumber.valueOr:
    return false

  let
    blockEpoch = blockSlot div SLOTS_PER_EPOCH
    headEpoch = headSlot div SLOTS_PER_EPOCH

  blockEpoch + BAL_RETENTION_EPOCHS > headEpoch

func accChangesCmp*(x, y: AccountChanges): int =
  cmp(x.address.data(), y.address.data())

func slotChangesCmp*(x, y: SlotChanges): int =
  cmp(x.slot, y.slot)

func balIndexCmp*(x, y: StorageChange | BalanceChange | NonceChange | CodeChange): int =
  cmp(x.blockAccessIndex, y.blockAccessIndex)

# This custom compare proc is used to check for duplicates in the same
# iteration that checks if each list is sorted. This is more efficient
# than doing two iterations.
proc cmpTreatEqualAsGreater[T](x, y: T): int =
  if x < y: -1 else: 1

func accChangesCmpTreatEqualAsGreater*(x, y: AccountChanges): int =
  cmpTreatEqualAsGreater(x.address.data(), y.address.data())

func slotChangesCmpTreatEqualAsGreater*(x, y: SlotChanges): int =
  cmpTreatEqualAsGreater(x.slot, y.slot)

func balIndexCmpTreatEqualAsGreater*(
    x, y: StorageChange | BalanceChange | NonceChange | CodeChange
): int =
  cmpTreatEqualAsGreater(x.blockAccessIndex, y.blockAccessIndex)

func storageKeyCmpTreatEqualAsGreater*(x, y: StorageKey): int =
  cmpTreatEqualAsGreater(x, y)

func findAccountChanges*(bal: BlockAccessList, address: Address): int =
  # The BAL is assumed to be sorted by address
  binarySearch(
    bal,
    address,
    proc(x: AccountChanges, y: Address): int =
      cmp(x.address.data(), y.data()),
  )

func findSlotChanges*(storageChanges: openArray[SlotChanges], slot: StorageKey): int =
  # The storage changes are assumed to be sorted by slot
  binarySearch(
    storageChanges,
    slot,
    proc(x: SlotChanges, y: StorageKey): int =
      cmp(x.slot, y),
  )

func findLastWriteBefore*[T: StorageChange | BalanceChange | NonceChange | CodeChange](
    changes: openArray[T], balIndex: int
): int =
  # The changes list is assumed to be sorted by bal index
  var
    lo = 0
    hi = changes.len() - 1
    foundAt = -1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    if changes[mid].blockAccessIndex.int < balIndex:
      foundAt = mid
      lo = mid + 1
    else:
      hi = mid - 1

  foundAt

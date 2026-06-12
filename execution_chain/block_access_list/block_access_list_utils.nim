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
  eth/common/[addresses, block_access_lists],
  stew/byteutils

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
  var
    lo = 0
    hi = bal.len() - 1
  while lo <= hi:
    let
      mid = (lo + hi) shr 1
      c = cmp(bal[mid].address.data(), address.data())
    if c == 0:
      return mid
    elif c < 0:
      lo = mid + 1
    else:
      hi = mid - 1
  -1

func findSlotChanges*(storageChanges: openArray[SlotChanges], slot: StorageKey): int =
  var
    lo = 0
    hi = storageChanges.len() - 1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    if storageChanges[mid].slot == slot:
      return mid
    elif storageChanges[mid].slot < slot:
      lo = mid + 1
    else:
      hi = mid - 1
  -1

func findStorageRead*(storageReads: openArray[StorageKey], slot: StorageKey): int =
  var
    lo = 0
    hi = storageReads.len() - 1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    if storageReads[mid] == slot:
      return mid
    elif storageReads[mid] < slot:
      lo = mid + 1
    else:
      hi = mid - 1
  -1

func findLastWriteBefore*[T: StorageChange | BalanceChange | NonceChange | CodeChange](
    changes: openArray[T], balIndex: int
): int =
  var
    lo = 0
    hi = changes.len() - 1
  result = -1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    if changes[mid].blockAccessIndex.int < balIndex:
      result = mid
      lo = mid + 1
    else:
      hi = mid - 1

func findWriteAt*[T: StorageChange | BalanceChange | NonceChange | CodeChange](
    changes: openArray[T], balIndex: int
): int =
  var
    lo = 0
    hi = changes.len() - 1
  while lo <= hi:
    let
      mid = (lo + hi) shr 1
      c = cmp(changes[mid].blockAccessIndex.int, balIndex)
    if c == 0:
      return mid
    elif c < 0:
      lo = mid + 1
    else:
      hi = mid - 1
  -1

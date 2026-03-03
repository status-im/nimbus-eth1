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

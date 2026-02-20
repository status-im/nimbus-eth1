# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import eth/common/[block_access_lists], stew/byteutils

func accChangesCmp*(x, y: AccountChanges): int =
  cmp(x.address.data.toHex(), y.address.data.toHex())

func slotChangesCmp*(x, y: SlotChanges): int =
  cmp(x.slot, y.slot)

func balIndexCmp*(x, y: StorageChange | BalanceChange | NonceChange | CodeChange): int =
  cmp(x.blockAccessIndex, y.blockAccessIndex)

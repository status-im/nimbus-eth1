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
  stint,
  results,
  ./block_access_list_utils

export addresses, block_access_lists, results

type
  BlockAccessListOverlayRef* = ref object
    bal: ptr BlockAccessList
    balIndex: int

  OverlayAccount* = object
    balance*: Opt[UInt256]
    nonce*: Opt[AccountNonce]
    code*: Opt[Bytecode]

func init*(
    T: type BlockAccessListOverlayRef, bal: ptr BlockAccessList, balIndex: int
): T =
  doAssert not bal.isNil()
  BlockAccessListOverlayRef(bal: bal, balIndex: balIndex)

func exists*(acc: OverlayAccount): bool =
  acc.balance.isSome() or acc.nonce.isSome() or acc.code.isSome()

func getAccount*(
    overlay: BlockAccessListOverlayRef, address: Address
): OverlayAccount =
  let i = overlay.bal[].findAccountChanges(address)
  if i < 0:
    return

  template accChanges(): AccountChanges =
    overlay.bal[][i]

  let balancePos = accChanges.balanceChanges.findLastWriteBefore(overlay.balIndex)
  if balancePos >= 0:
    result.balance = Opt.some(accChanges.balanceChanges[balancePos].postBalance)

  let noncePos = accChanges.nonceChanges.findLastWriteBefore(overlay.balIndex)
  if noncePos >= 0:
    result.nonce = Opt.some(accChanges.nonceChanges[noncePos].newNonce)

  let codePos = accChanges.codeChanges.findLastWriteBefore(overlay.balIndex)
  if codePos >= 0:
    result.code = Opt.some(accChanges.codeChanges[codePos].newCode)

func getStorage*(
    overlay: BlockAccessListOverlayRef, address: Address, slot: UInt256
): Opt[UInt256] =
  let i = overlay.bal[].findAccountChanges(address)
  if i < 0:
    return Opt.none(UInt256)

  template accChanges(): AccountChanges =
    overlay.bal[][i]

  let slotPos = accChanges.storageChanges.findSlotChanges(slot)
  if slotPos < 0:
    return Opt.none(UInt256)

  let changePos =
    accChanges.storageChanges[slotPos].changes.findLastWriteBefore(overlay.balIndex)
  if changePos < 0:
    return Opt.none(UInt256)

  Opt.some(accChanges.storageChanges[slotPos].changes[changePos].newValue)

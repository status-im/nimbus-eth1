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
  std/tables,
  eth/common/[addresses, block_access_lists], stint, results, ./block_access_list_utils

export addresses, block_access_lists, results

# The BlockAccessList pointer is not owned or managed by the BlockAccessListOverlay
# and therefore it must outlive and exist longer than the overlay.
# The passed in BAL must already be validated and therefore sorted according to the
# EIP-7928 spec rules. 

type
  BlockAccessListOverlay* = object
    bal: ptr BlockAccessList
    balIndex: int
    accIndexes: Table[Address, int] 

  OverlayAccount* = object
    balance*: Opt[UInt256]
    nonce*: Opt[AccountNonce]
    code*: Opt[Bytecode]

const emptyOverlayAcc* = default(OverlayAccount)

func init*(
    T: type BlockAccessListOverlay, bal: ptr BlockAccessList, balIndex: int
): T =
  doAssert not bal.isNil()
  T(bal: bal, balIndex: balIndex, accIndexes: initTable[Address, int]())

proc `=copy`(
    dest: var BlockAccessListOverlay, src: BlockAccessListOverlay
) {.error: "Copying BlockAccessListOverlay is forbidden".} =
  discard

proc findAccount(overlay: var BlockAccessListOverlay, address: Address): int =
  overlay.accIndexes.withValue(address, cached):
    return cached[]
  do:
    result = overlay.bal[].findAccountChanges(address)
    overlay.accIndexes[address] = result

proc hasAccount*(overlay: var BlockAccessListOverlay, address: Address): bool =
  let i = overlay.findAccount(address)
  if i < 0:
    return false

  template accChanges(): AccountChanges =
    overlay.bal[][i]

  if accChanges.balanceChanges.findLastWriteBefore(overlay.balIndex) >= 0 or
      accChanges.nonceChanges.findLastWriteBefore(overlay.balIndex) >= 0 or
      accChanges.codeChanges.findLastWriteBefore(overlay.balIndex) >= 0:
    return true

  for slotChanges in accChanges.storageChanges:
    if slotChanges.changes.findLastWriteBefore(overlay.balIndex) >= 0:
      return true

  false

proc getAccount*(overlay: var BlockAccessListOverlay, address: Address): OverlayAccount =
  let i = overlay.findAccount(address)
  if i < 0:
    return emptyOverlayAcc

  template accChanges(): AccountChanges =
    overlay.bal[][i]

  var overlayAcc: OverlayAccount
  let balancePos = accChanges.balanceChanges.findLastWriteBefore(overlay.balIndex)
  if balancePos >= 0:
    overlayAcc.balance = Opt.some(accChanges.balanceChanges[balancePos].postBalance)

  let noncePos = accChanges.nonceChanges.findLastWriteBefore(overlay.balIndex)
  if noncePos >= 0:
    overlayAcc.nonce = Opt.some(accChanges.nonceChanges[noncePos].newNonce)

  let codePos = accChanges.codeChanges.findLastWriteBefore(overlay.balIndex)
  if codePos >= 0:
    overlayAcc.code = Opt.some(accChanges.codeChanges[codePos].newCode)

  overlayAcc

proc getStorage*(
    overlay: var BlockAccessListOverlay, address: Address, slot: UInt256
): Opt[UInt256] =
  let i = overlay.findAccount(address)
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

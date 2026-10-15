# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables, sets],
  stint,
  eth/common/[addresses, transactions],
  ../utils/mergeutils

export addresses

type
  SlotSet = HashSet[UInt256]

  AccessList* = object
    addresses  : HashSet[Address]
    storageKeys: Table[Address, SlotSet]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toStorageKeys(slots: SlotSet): seq[Bytes32] =
  for slot in slots:
    result.add slot.to(Bytes32)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func contains*(al: AccessList, address: Address): bool {.inline.} =
  address in al.addresses

# returnValue: (addressPresent, slotPresent)
func contains*(al: AccessList, address: Address, slot: UInt256): bool =
  al.storageKeys.withValue(address, val):
    return slot in val

proc mergeAndReset*(al, other: var AccessList) =
  # move values in `other` to `al`
  al.addresses.mergeAndReset(other.addresses)
  al.storageKeys.mergeAndReset(other.storageKeys)

proc add*(al: var AccessList, address: Address) =
  al.addresses.incl address

proc add*(al: var AccessList, address: Address, slot: UInt256) =
  al.storageKeys.withValue(address, val):
    val[].incl slot
  do:
    al.storageKeys[address] = toHashSet([slot])

proc clear*(al: var AccessList) {.inline.} =
  al.addresses.clear()
  al.storageKeys.clear()

func getAccessList*(al: AccessList): transactions.AccessList =
  for address, slots in al.storageKeys:
    result.add transactions.AccessPair(
      address    : address,
      storageKeys: slots.toStorageKeys,
    )
  for address in al.addresses:
    if address notin al.storageKeys:
      result.add transactions.AccessPair(
        address: address,
      )

func equal*(al: AccessList, other: AccessList): bool =
  if al.addresses.len != other.addresses.len:
    return false

  if al.storageKeys.len != other.storageKeys.len:
    return false

  for address in al.addresses:
    if address notin other.addresses:
      return false

  for address, otherSlots in other.storageKeys:
    al.storageKeys.withValue(address, thisSlots):
      if otherSlots.len != thisSlots.len:
        return false

      for slot in otherSlots:
        if slot notin thisSlots:
          return false
    do:
      return false

  true

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
    slots: Table[Address, SlotSet]

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
  address in al.slots

# returnValue: (addressPresent, slotPresent)
func contains*(al: var AccessList, address: Address, slot: UInt256): bool =
  al.slots.withValue(address, val):
    result = slot in val[]

proc mergeAndReset*(al, other: var AccessList) =
  # move values in `other` to `al`
  al.slots.mergeAndReset(other.slots)

proc add*(al: var AccessList, address: Address) =
  if address notin al.slots:
    al.slots[address] = HashSet[UInt256]()

proc add*(al: var AccessList, address: Address, slot: UInt256) =
  al.slots.withValue(address, val):
    val[].incl slot
  do:
    al.slots[address] = toHashSet([slot])

proc clear*(al: var AccessList) {.inline.} =
  al.slots.clear()

func getAccessList*(al: AccessList): transactions.AccessList =
  for address, slots in al.slots:
    result.add transactions.AccessPair(
      address    : address,
      storageKeys: slots.toStorageKeys,
    )

func equal*(al: AccessList, other: var AccessList): bool =
  if al.slots.len != other.slots.len:
    return false

  for address, slots in al.slots:
    other.slots.withValue(address, otherSlots):
      if slots.len != otherSlots[].len:
        return false

      for slot in slots:
        if slot notin otherSlots[]:
          return false
    do:
      return false

  true

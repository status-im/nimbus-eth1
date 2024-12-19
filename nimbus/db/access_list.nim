# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
# Public constructors
# ------------------------------------------------------------------------------

proc init*(ac: var AccessList) =
  ac.slots = Table[Address, SlotSet]()

proc init*(_: type AccessList): AccessList {.inline.} =
  result.init()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func contains*(ac: AccessList, address: Address): bool {.inline.} =
  address in ac.slots

# returnValue: (addressPresent, slotPresent)
func contains*(ac: var AccessList, address: Address, slot: UInt256): bool =
  ac.slots.withValue(address, val):
    result = slot in val[]

proc mergeAndReset*(ac, other: var AccessList) =
  # move values in `other` to `ac`
  ac.slots.mergeAndReset(other.slots)

proc add*(ac: var AccessList, address: Address) =
  if address notin ac.slots:
    ac.slots[address] = HashSet[UInt256]()

proc add*(ac: var AccessList, address: Address, slot: UInt256) =
  ac.slots.withValue(address, val):
    val[].incl slot
  do:
    ac.slots[address] = toHashSet([slot])

proc clear*(ac: var AccessList) {.inline.} =
  ac.slots.clear()

func getAccessList*(ac: AccessList): transactions.AccessList =
  for address, slots in ac.slots:
    result.add transactions.AccessPair(
      address    : address,
      storageKeys: slots.toStorageKeys,
    )

func equal*(ac: AccessList, other: var AccessList): bool =
  if ac.slots.len != other.slots.len:
    return false

  for address, slots in ac.slots:
    other.slots.withValue(address, otherSlots):
      if slots.len != otherSlots[].len:
        return false

      for slot in slots:
        if slot notin otherSlots[]:
          return false
    do:
      return false

  true

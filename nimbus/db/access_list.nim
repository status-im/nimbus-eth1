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
  eth/common

type
  SlotSet = HashSet[UInt256]

  AccessList* = object
    slots: Table[EthAddress, SlotSet]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toStorageKeys(slots: SlotSet): StorageKeys =
  for slot in slots:
    let ok = result.add slot.toBytesBE()
    doAssert ok, "StorageKeys capacity exceeded"

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc init*(ac: var AccessList) =
  ac.slots = initTable[EthAddress, SlotSet]()

proc init*(_: type AccessList): AccessList {.inline.} =
  result.init()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func contains*(ac: AccessList, address: EthAddress): bool {.inline.} =
  address in ac.slots

# returnValue: (addressPresent, slotPresent)
func contains*(ac: var AccessList, address: EthAddress, slot: UInt256): bool =
  ac.slots.withValue(address, val):
    result = slot in val[]

proc merge*(ac: var AccessList, other: AccessList) {.inline.} =
  for k, v in other.slots:
    ac.slots.withValue(k, val):
      val[].incl v
    do:
      ac.slots[k] = v

proc add*(ac: var AccessList, address: EthAddress) =
  if address notin ac.slots:
    ac.slots[address] = initHashSet[UInt256]()

proc add*(ac: var AccessList, address: EthAddress, slot: UInt256) =
  ac.slots.withValue(address, val):
    val[].incl slot
  do:
    ac.slots[address] = toHashSet([slot])

proc clear*(ac: var AccessList) {.inline.} =
  ac.slots.clear()

func getAccessList*(ac: AccessList): common.AccessList =
  for address, slots in ac.slots:
    let ok = result.add common.AccessPair(
      address    : address,
      storageKeys: slots.toStorageKeys,
    )
    doAssert ok, "AccessList capacity exceeded"

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

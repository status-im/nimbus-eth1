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
    codeHashes: seq[Hash32]

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
  ac.codeHashes = newSeq[Hash32]()

proc init*(_: type AccessList): AccessList {.inline.} =
  result.init()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func contains*(ac: accesslist, address: address): bool {.inline.} =
  address in ac.slots

func contains*(ac: accesslist, codeHash: Hash32): bool {.inline.} =
  codeHash in ac.codeHashes

# returnValue: (addressPresent, slotPresent)
func contains*(ac: var AccessList, address: Address, slot: UInt256): bool =
  ac.slots.withValue(address, val):
    result = slot in val[]

proc mergeAndReset*(ac, other: var AccessList) =
  # move values in `other` to `ac`
  ac.slots.mergeAndReset(other.slots)
  ac.codeHashes.mergeAndReset(other.codeHashes)

proc add*(ac: var AccessList, address: Address) =
  if address notin ac.slots:
    ac.slots[address] = HashSet[UInt256]()

proc add*(ac: var AccessList, address: Address, slot: UInt256) =
  ac.slots.withValue(address, val):
    val[].incl slot
  do:
    ac.slots[address] = toHashSet([slot])

proc add*(ac: var AccessList, codeHash: Hash32) =
  if codeHash not in ac.codeHashes:
    ac.codeHashes.add(codeHash)

proc clear*(ac: var AccessList) {.inline.} =
  ac.slots.clear()
  ac.codeHashes.setLen(0)

# TODO: accesses code is still not a part of the transaction access list
# but when it does trickle down into the transaction we will have to add
# it here
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

  for codeHash in ac.codeHashes:
    if codeHash not in other:
      return false

  true

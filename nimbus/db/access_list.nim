import
  tables, sets,
  stint,
  eth/common

type
  SlotSet = HashSet[UInt256]

  AccessList* = object
    slots: Table[EthAddress, SlotSet]

proc init*(ac: var AccessList) =
  ac.slots = initTable[EthAddress, SlotSet]()

proc init*(_: type AccessList): AccessList {.inline.} =
  result.init()

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

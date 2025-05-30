# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  tables,
  stint,
  eth/common/addresses,
  ../utils/mergeutils

type
  StorageTable = ref object
    map: Table[UInt256, UInt256]

  TransientStorage* = object
    map: Table[Address, StorageTable]

#######################################################################
# Private helpers
#######################################################################

proc mergeAndDiscard*(trg, src: var UInt256) =
  trg = src # no need to reset, the entire source map gets cleared

proc mergeAndDiscard*(a, b: StorageTable) =
  a.map.mergeAndReset(b.map)

#######################################################################
# Public functions
#######################################################################

proc init*(ac: var TransientStorage) =
  ac.map = Table[Address, StorageTable]()

proc init*(_: type TransientStorage): TransientStorage {.inline.} =
  result.init()

func getStorage*(ac: TransientStorage,
                 address: Address, slot: UInt256): (bool, UInt256) =
  var table = ac.map.getOrDefault(address)
  if table.isNil:
    return (false, 0.u256)

  table.map.withValue(slot, val):
    return (true, val[])
  do:
    return (false, 0.u256)

proc setStorage*(ac: var TransientStorage,
                 address: Address, slot, value: UInt256) =
  var table = ac.map.getOrDefault(address)
  if table.isNil:
    table = StorageTable()
    ac.map[address] = table

  table.map[slot] = value

proc mergeAndReset*(ac, other: var TransientStorage) =
  ac.map.mergeAndReset(other.map)

proc clear*(ac: var TransientStorage) {.inline.} =
  ac.map.clear()

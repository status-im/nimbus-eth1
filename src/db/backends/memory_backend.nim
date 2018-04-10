# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import tables, ttmath

type
  MemoryDB* = ref object
    kvStore*: Table[string, Int256]

proc newMemoryDB*(kvStore: Table[string, Int256]): MemoryDB =
  MemoryDB(kvStore: kvStore)

proc newMemoryDB*: MemoryDB =
  MemoryDB(kvStore: initTable[string, Int256]())

proc get*(db: MemoryDB, key: string): Int256 =
  db.kvStore[key]

proc set*(db: var MemoryDB, key: string, value: Int256) =
  db.kvStore[key] = value

proc exists*(db: MemoryDB, key: string): bool =
  db.kvStore.hasKey(key)

proc delete*(db: var MemoryDB, key: string) =
  db.kvStore.del(key)

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import tables
import ranges
import ../storage_types

type
  MemoryDB* = ref object
    kvStore*: Table[DbKey, ByteRange]

proc newMemoryDB*: MemoryDB =
  MemoryDB(kvStore: initTable[DbKey, ByteRange]())

proc get*(db: MemoryDB, key: DbKey): ByteRange =
  db.kvStore[key]

proc set*(db: var MemoryDB, key: DbKey, value: ByteRange) =
  db.kvStore[key] = value

proc contains*(db: MemoryDB, key: DbKey): bool =
  db.kvStore.hasKey(key)

proc delete*(db: var MemoryDB, key: DbKey) =
  db.kvStore.del(key)


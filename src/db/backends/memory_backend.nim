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

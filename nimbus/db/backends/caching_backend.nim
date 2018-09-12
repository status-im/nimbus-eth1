import ranges, eth_trie, tables, sets
import ../storage_types

type
  CachingDB* = ref object of RootObj
    backing: TrieDatabaseRef
    changed: Table[seq[byte], seq[byte]]
    deleted: HashSet[seq[byte]]

proc newCachingDB*(backing: TrieDatabaseRef): CachingDB =
  result.new()
  result.backing = backing
  result.changed = initTable[seq[byte], seq[byte]]()
  result.deleted = initSet[seq[byte]]()

proc get*(db: CachingDB, key: openarray[byte]): seq[byte] =
  let key = @key
  result = db.changed.getOrDefault(key)
  if result.len == 0 and key notin db.deleted:
    result = db.backing.get(key)

proc put*(db: CachingDB, key, value: openarray[byte]) =
  let key = @key
  db.deleted.excl(key)
  db.changed[key] = @value

proc contains*(db: CachingDB, key: openarray[byte]): bool =
  let key = @key
  result = key in db.changed
  if not result and key notin db.deleted:
    result = db.backing.contains(key)

proc del*(db: CachingDB, key: openarray[byte]) =
  let key = @key
  db.changed.del(key)
  db.deleted.incl(key)

proc commit*(db: CachingDB) =
  for k in db.deleted:
    db.backing.del(k)

  for k, v in db.changed:
    db.backing.put(k, v)


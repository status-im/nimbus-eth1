import eth_trie/db, ranges

type
  CaptureFlags* {.pure.} = enum
    PersistPut
    PersistDel

  DB = TrieDatabaseRef
  BytesRange = Range[byte]

  CaptureDB* = ref object of RootObj
    srcDb: DB
    dstDb: DB
    flags: set[CaptureFlags]

proc get*(db: CaptureDB, key: openArray[byte]): seq[byte] =
  result = db.dstDb.get(key)
  if result.len != 0: return
  result = db.srcDb.get(key)
  if result.len == 0:
    db.dstDb.put(key, result)

proc put*(db: CaptureDB, key, value: openArray[byte]) =
  db.dstDb.put(key, value)
  if CaptureFlags.PersistPut in db.flags:
    db.srcDb.put(key, value)

proc contains*(db: CaptureDB, key: openArray[byte]): bool =
  result = db.srcDb.contains(key)
  assert(db.dstDb.contains(key) == result)

proc del*(db: CaptureDB, key: openArray[byte]) =
  db.dstDb.del(key)
  if CaptureFlags.PersistDel in db.flags:
    db.srcDb.del(key)

proc newCaptureDB*(srcDb, dstDb: DB, flags: set[CaptureFlags] = {}): CaptureDB =
  result.new()
  result.srcDb = srcDb
  result.dstDb = dstDb
  result.flags = flags

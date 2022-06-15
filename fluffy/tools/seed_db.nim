# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/options,
  eth/db/kvstore,
  eth/db/kvstore_sqlite3,
  stint

export kvstore_sqlite3

type
  ContentData = tuple
    contentId: array[32, byte]
    contentKey: seq[byte]
    content: seq[byte]

  ContentDataDist = tuple
    contentId: array[32, byte]
    contentKey: seq[byte]
    content: seq[byte]
    distance: array[32, byte]
  
  SeedDb* = ref object
    store: SqStoreRef
    putStmt: SqliteStmt[(array[32, byte], seq[byte], seq[byte]), void]
    getStmt: SqliteStmt[array[32, byte], ContentData]
    getInRangeStmt: SqliteStmt[(array[32, byte], array[32, byte], int64), ContentDataDist]

func xorDistance(
  a: openArray[byte],
  b: openArray[byte]
): Result[seq[byte], cstring] {.cdecl.} =
  var s: seq[byte] = newSeq[byte](32)

  if len(a) != 32 or len(b) != 32:
    return err("Blobs should have 32 byte length")

  var i = 0
  while i < 32:
    s[i] = a[i] xor b[i]
    inc i

  return ok(s)

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

proc new*(T: type SeedDb, path: string, name: string, inMemory = false): SeedDb =
  let db =
    if inMemory:
      SqStoreRef.init("", "seed-db-test", inMemory = true).expect(
        "working database (out of memory?)")
    else:
      SqStoreRef.init(path, name).expectDb()

  if not db.readOnly:
    let createSql = """
      CREATE TABLE IF NOT EXISTS seed_data (
         contentid BLOB PRIMARY KEY,
         contentkey BLOB,
         content BLOB
      );"""

    db.exec(createSql).expectDb()

  let putStmt = 
    db.prepareStmt(
      "INSERT OR REPLACE INTO seed_data (contentid, contentkey, content) VALUES (?, ?, ?);",
      (array[32, byte], seq[byte], seq[byte]),
      void).get()

  let getStmt = 
    db.prepareStmt(
      "SELECT contentid, contentkey, content FROM seed_data WHERE contentid = ?;",
      array[32, byte],
      ContentData
    ).get()

  db.registerCustomScalarFunction("xorDistance", xorDistance)
    .expect("Couldn't register custom xor function")

  let getInRangeStmt = 
    db.prepareStmt(
      """
        SELECT contentid, contentkey, content, xorDistance(?, contentid) as distance 
        FROM seed_data
        WHERE distance <= ?
        LIMIT ?;
      """,
      (array[32, byte], array[32, byte], int64),
      ContentDataDist
    ).get()

  SeedDb(
    store: db,
    putStmt: putStmt,
    getStmt: getStmt,
    getInRangeStmt: getInRangeStmt
  )

proc put*(db: SeedDb, contentId: array[32, byte], contentKey: seq[byte], content: seq[byte]): void = 
  db.putStmt.exec((contentId, contentKey, content)).expectDb()

proc put*(db: SeedDb, contentId: UInt256, contentKey: seq[byte], content: seq[byte]): void = 
  db.put(contentId.toByteArrayBE(), contentKey, content)

proc get*(db: SeedDb, contentId: array[32, byte]): Option[ContentData] =
  var res = none[ContentData]()
  discard db.getStmt.exec(contentId, proc (v: ContentData) = res = some(v)).expectDb()
  return res

proc get*(db: SeedDb, contentId: UInt256): Option[ContentData] =
  db.get(contentId.toByteArrayBE())

proc getContentInRange*(
    db: SeedDb,
    nodeId: UInt256,
    nodeRadius: UInt256,
    max: int64): seq[ContentDataDist] =
  
  var res: seq[ContentDataDist] = @[]
  var cd: ContentDataDist
  for e in db.getInRangeStmt.exec((nodeId.toByteArrayBE(), nodeRadius.toByteArrayBE(), max), cd):
    res.add(cd)
  return res

proc close*(db: SeedDb) =
  db.store.close()

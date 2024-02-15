# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[options, os],
  strutils,
  eth/db/kvstore,
  eth/db/kvstore_sqlite3,
  stint,
  ./content_db_custom_sql_functions

export kvstore_sqlite3

type
  ContentData = tuple
    contentId: array[32, byte]
    contentKey: seq[byte]
    content: seq[byte]

  ContentDataDist* = tuple
    contentId: array[32, byte]
    contentKey: seq[byte]
    content: seq[byte]
    distance: array[32, byte]

  SeedDb* = ref object
    store: SqStoreRef
    putStmt: SqliteStmt[(array[32, byte], seq[byte], seq[byte]), void]
    getStmt: SqliteStmt[array[32, byte], ContentData]
    getInRangeStmt: SqliteStmt[(array[32, byte], array[32, byte], int64, int64), ContentDataDist]

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

proc getDbBasePathAndName*(path: string): Option[(string, string)] =
  let (basePath, name) = splitPath(path)
  if len(basePath) > 0 and len(name) > 0 and name.endsWith(".sqlite3"):
    let nameAndExt = rsplit(name, ".", 1)

    if len(nameAndExt) < 2 and len(nameAndExt[0]) == 0:
      return none((string, string))

    return some((basePath, nameAndExt[0]))
  else:
    return none((string, string))

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
      void)[]

  let getStmt =
    db.prepareStmt(
      "SELECT contentid, contentkey, content FROM seed_data WHERE contentid = ?;",
      array[32, byte],
      ContentData
    )[]

  db.createCustomFunction("xorDistance", 2, xorDistance).expect(
    "Custom function xorDistance creation OK")

  let getInRangeStmt =
    db.prepareStmt(
      """
        SELECT contentid, contentkey, content, xorDistance(?, contentid) as distance
        FROM seed_data
        WHERE distance <= ?
        LIMIT ?
        OFFSET ?;
      """,
      (array[32, byte], array[32, byte], int64, int64),
      ContentDataDist
    )[]

  SeedDb(
    store: db,
    putStmt: putStmt,
    getStmt: getStmt,
    getInRangeStmt: getInRangeStmt
  )

proc put*(db: SeedDb, contentId: array[32, byte], contentKey: seq[byte], content: seq[byte]): void =
  db.putStmt.exec((contentId, contentKey, content)).expectDb()

proc put*(db: SeedDb, contentId: UInt256, contentKey: seq[byte], content: seq[byte]): void =
  db.put(contentId.toBytesBE(), contentKey, content)

proc get*(db: SeedDb, contentId: array[32, byte]): Option[ContentData] =
  var res = none[ContentData]()
  discard db.getStmt.exec(contentId, proc (v: ContentData) = res = some(v)).expectDb()
  return res

proc get*(db: SeedDb, contentId: UInt256): Option[ContentData] =
  db.get(contentId.toBytesBE())

proc getContentInRange*(
    db: SeedDb,
    nodeId: UInt256,
    nodeRadius: UInt256,
    max: int64,
    offset: int64): seq[ContentDataDist] =
  ## Return `max` amount of content in `nodeId` range, starting from `offset` position
  ## i.e using `offset` 0 will return `max` closest items, using `offset` `10` will
  ## will retrun `max` closest items except first 10

  var res: seq[ContentDataDist] = @[]
  var cd: ContentDataDist
  for e in db.getInRangeStmt.exec((nodeId.toBytesBE(), nodeRadius.toBytesBE(), max, offset), cd):
    res.add(cd)
  return res

proc getContentInRange*(
    db: SeedDb,
    nodeId: UInt256,
    nodeRadius: UInt256,
    max: int64): seq[ContentDataDist] =
  ## Return `max` amount of content in `nodeId` range, starting from closest content
  return db.getContentInRange(nodeId, nodeRadius, max, 0)

proc close*(db: SeedDb) =
  db.store.close()

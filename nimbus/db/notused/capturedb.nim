# Nimbus
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import eth/trie/db

type
  CaptureFlags* {.pure.} = enum
    PersistPut
    PersistDel

  DB = TrieDatabaseRef

  CaptureDB* = ref object of RootObj
    srcDb: DB
    dstDb: DB
    flags: set[CaptureFlags]

proc get*(db: CaptureDB, key: openArray[byte]): seq[byte] =
  result = db.dstDb.get(key)
  if result.len != 0: return
  result = db.srcDb.get(key)
  if result.len != 0:
    db.dstDb.put(key, result)

proc put*(db: CaptureDB, key, value: openArray[byte]) =
  db.dstDb.put(key, value)
  if CaptureFlags.PersistPut in db.flags:
    db.srcDb.put(key, value)

proc contains*(db: CaptureDB, key: openArray[byte]): bool =
  result = db.srcDb.contains(key)
  doAssert(db.dstDb.contains(key) == result)

proc del*(db: CaptureDB, key: openArray[byte]) =
  db.dstDb.del(key)
  if CaptureFlags.PersistDel in db.flags:
    db.srcDb.del(key)

proc newCaptureDB*(srcDb, dstDb: DB, flags: set[CaptureFlags] = {}): CaptureDB =
  result.new()
  result.srcDb = srcDb
  result.dstDb = dstDb
  result.flags = flags

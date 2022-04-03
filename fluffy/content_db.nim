# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[options, heapqueue],
  eth/db/kvstore,
  eth/db/kvstore_sqlite3,
  stint,
  ./network/state/state_content

export kvstore_sqlite3

# This version of content db is the most basic, simple solution where data is
# stored no matter what content type or content network in the same kvstore with
# the content id as key. The content id is derived from the content key, and the
# deriviation is different depending on the content type. As we use content id,
# this part is currently out of the scope / API of the ContentDB.
# In the future it is likely that that either:
# 1. More kvstores are added per network, and thus depending on the network a
# different kvstore needs to be selected.
# 2. Or more kvstores are added per network and per content type, and thus
# content key fields are required to access the data.
# 3. Or databases are created per network (and kvstores pre content type) and
# thus depending on the network the right db needs to be selected.

type
  RowInfo = tuple
    contentId: array[32, byte]
    payloadLength: int64

  ObjInfo* = object
    contentId*: array[32, byte]
    payloadLength*: int64
    distFrom*: UInt256

  ContentDB* = ref object
    kv: KvStoreRef
    sizeStmt: SqliteStmt[NoParams, int64]
    vacStmt: SqliteStmt[NoParams, void]
    getAll: SqliteStmt[NoParams, RowInfo]

# we want objects to be sorted from largest distance to closests
proc `<`(a, b: ObjInfo): bool = 
  return a.distFrom < b.distFrom

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

proc new*(T: type ContentDB, path: string, inMemory = false): ContentDB =
  let db =
    if inMemory:
      SqStoreRef.init("", "fluffy-test", inMemory = true).expect(
        "working database (out of memory?)")
    else:
      SqStoreRef.init(path, "fluffy").expectDb()

  let getSizeStmt = db.prepareStmt(
    "SELECT page_count * page_size as size FROM pragma_page_count(), pragma_page_size();",
    NoParams, int64).get()

  let vacStmt = db.prepareStmt(
    "VACUUM;",
    NoParams, void).get()

  let kvStore = kvStore db.openKvStore().expectDb()

  # this need to go after `openKvStore`, as it checks that the table name kvstore
  # already exists.
  let getKeysStmt = db.prepareStmt(
    "SELECT key, length(value) FROM kvstore",
    NoParams, RowInfo
  ).get()

  ContentDB(kv: kvStore, sizeStmt: getSizeStmt, vacStmt: vacStmt, getAll: getKeysStmt)

proc getNFurthestElements*(db: ContentDB, target: UInt256, n: uint64): seq[ObjInfo] =
  ## Get at most n furthest elements from database in order from furthest to closest.
  ## We are also returning payload lengths so caller can decide how many of those elements
  ## need to be deleted.
  ## 
  ## Currently it uses xor metric
  ## 
  ## Currently works by querying for all elements in database and doing all necessary 
  ## work on program level. This is mainly due to two facts:
  ## - sqlite does not have build xor function, also it does not handle bitwise
  ## operations on blobs as expected
  ## - our nim wrapper for sqlite does not support create_function api of sqlite
  ## so we cannot create custom function comparing blobs at sql level. If that 
  ## would be possible we may be able to all this work by one sql query

  if n == 0:
    return newSeq[ObjInfo]()

  var heap = initHeapQueue[ObjInfo]()

  var ri: RowInfo
  for e in db.getAll.exec(ri):
    let contentId = UInt256.fromBytesBE(ri.contentId)
    # TODO: Currently it assumes xor distance, but when we start testing networks with
    # other distance functions this needs to be adjusted to the custom distance function
    let dist = contentId xor target
    let obj = ObjInfo(contentId: ri.contentId, payloadLength: ri.payloadLength, distFrom: dist)
    
    if (uint64(len(heap)) < n):
      heap.push(obj)
    else:
      if obj > heap[0]:
        discard heap.replace(obj)

  var res: seq[ObjInfo] = newSeq[ObjInfo](heap.len())

  var i = heap.len() - 1
  while heap.len() > 0:
    res[i] = heap.pop()
    dec i

  return res

proc reclaimSpace*(db: ContentDB): void =
  ## Runs sqlie VACUMM commands which rebuilds db, repacking it into a minimal amount of disk space
  ## Ideal mode of operation, is to run it after several deletes.
  ## Another options would be to run 'PRAGMA auto_vacuum = FULL;' statement at the start of 
  ## db to leave it in sqlite power to clean up
  db.vacStmt.exec().expectDb()

proc size*(db: ContentDB): int64 =
  ## Retrun current size of DB as product of sqlite page_count and page_size
  ## https://www.sqlite.org/pragma.html#pragma_page_count
  ## https://www.sqlite.org/pragma.html#pragma_page_size
  ## It returns total size of db i.e both data and metadata used to store content
  ## also it is worth noting that when deleting content, size may lags behind due
  ## to the way how deleting works in sqlite.
  ## Good description can be found in: https://www.sqlite.org/lang_vacuum.html

  var size: int64 = 0
  discard (db.sizeStmt.exec do(res: int64):
    size = res).expectDb()
  return size

proc get*(db: ContentDB, key: openArray[byte]): Option[seq[byte]] =
  var res: Option[seq[byte]]
  proc onData(data: openArray[byte]) = res = some(@data)

  discard db.kv.get(key, onData).expectDb()

  return res

proc put*(db: ContentDB, key, value: openArray[byte]) =
  db.kv.put(key, value).expectDb()

proc contains*(db: ContentDB, key: openArray[byte]): bool =
  db.kv.contains(key).expectDb()

proc del*(db: ContentDB, key: openArray[byte]) =
  db.kv.del(key).expectDb()

# TODO: Could also decide to use the ContentKey SSZ bytestring, as this is what
# gets send over the network in requests, but that would be a bigger key. Or the
# same hashing could be done on it here.
# However ContentId itself is already derived through different digests
# depending on the content type, and this ContentId typically needs to be
# checked with the Radius/distance of the node anyhow. So lets see how we end up
# using this mostly in the code.

proc get*(db: ContentDB, key: ContentId): Option[seq[byte]] =
  # TODO: Here it is unfortunate that ContentId is a uint256 instead of Digest256.
  db.get(key.toByteArrayBE())

proc put*(db: ContentDB, key: ContentId, value: openArray[byte]) =
  db.put(key.toByteArrayBE(), value)

proc contains*(db: ContentDB, key: ContentId): bool =
  db.contains(key.toByteArrayBE())

proc del*(db: ContentDB, key: ContentId) =
  db.del(key.toByteArrayBE())

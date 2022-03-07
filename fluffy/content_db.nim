# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/options,
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
  ContentDB* = ref object
    kv: KvStoreRef
    sizeStmt: SqliteStmt[NoParams, int64]
    vacStmt: SqliteStmt[NoParams, void]

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

  ContentDB(kv: kvStore db.openKvStore().expectDb(), sizeStmt: getSizeStmt, vacStmt: vacStmt)

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

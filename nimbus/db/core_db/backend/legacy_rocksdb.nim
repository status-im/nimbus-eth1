# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/trie/db,
  eth/db/kvstore,
  rocksdb,
  ../base,
  ./legacy_db,
  ../../kvstore_rocksdb

type
  LegaPersDbRef = ref object of LegacyDbRef
    rdb: RocksStoreRef     # for backend access with legacy mode

  ChainDB = ref object of RootObj
    kv: KvStoreRef
    rdb: RocksStoreRef

# TODO KvStore is a virtual interface and TrieDB is a virtual interface - one
#      will be enough eventually - unless the TrieDB interface gains operations
#      that are not typical to KvStores
proc get(db: ChainDB, key: openArray[byte]): seq[byte] =
  var res: seq[byte]
  proc onData(data: openArray[byte]) = res = @data
  if db.kv.get(key, onData).expect("working database"):
    return res

proc put(db: ChainDB, key, value: openArray[byte]) =
  db.kv.put(key, value).expect("working database")

proc contains(db: ChainDB, key: openArray[byte]): bool =
  db.kv.contains(key).expect("working database")

proc del(db: ChainDB, key: openArray[byte]): bool =
  db.kv.del(key).expect("working database")

proc newChainDB(path: string): KvResult[ChainDB] =
  let rdb = RocksStoreRef.init(path, "nimbus").valueOr:
    return err(error)
  ok(ChainDB(kv: kvStore rdb, rdb: rdb))

# ------------------------------------------------------------------------------
# Public constructor and low level data retrieval, storage & transation frame
# ------------------------------------------------------------------------------

proc newLegacyPersistentCoreDbRef*(path: string): CoreDbRef =
  # when running `newChainDB(path)`. converted to a `Defect`.
  let backend = newChainDB(path).valueOr:
    let msg = "DB initialisation : " & error
    raise (ref ResultDefect)(msg: msg)

  proc done() =
    backend.rdb.close()

  LegaPersDbRef(rdb: backend.rdb).init(LegacyDbPersistent, backend.trieDB, done)

# ------------------------------------------------------------------------------
# Public helper for direct backend access
# ------------------------------------------------------------------------------

proc toRocksStoreRef*(db: CoreDbBackendRef): RocksStoreRef =
  if db.parent.dbType == LegacyDbPersistent:
    return db.parent.LegaPersDbRef.rdb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

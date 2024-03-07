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
  std/[tables, sequtils],
  eth/trie/db,
  eth/db/kvstore,
  rocksdb,
  ../base,
  ./legacy_db,
  ../../storage_types,
  ../../kvstore_rocksdb

type
  LegaPersDbRef = ref object of LegacyDbRef
    rdb: RocksStoreRef     # for backend access with legacy mode

  ChainDB = ref object of RootObj
    kv: KvStoreRef
    rdb: RocksStoreRef

proc `$`*(ns: DbNamespace): string =
  if ns == DbNamespace.default:
    return "default"
  $ord(ns)

proc getNamespaces(): seq[DbNamespace] =
  var namespaces = newSeq[DbNamespace]()
  for ns in DbNamespace.items():
    # Don't include the default namespace in the list because the main
    # RocksStoreRef uses the default namespace already
    if ns != DbNamespace.default:
      namespaces.add(ns)
  namespaces

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
  let rdb = RocksStoreRef.init(
      path,
      "nimbus",
      namespaces = getNamespaces().mapIt($it)).valueOr:
    return err(error)
  ok(ChainDB(kv: kvStore rdb, rdb: rdb))

proc withNamespace(db: ChainDB, ns: string): KvResult[ChainDB] =
  let nsDb = ? db.rdb.openNamespace(ns)
  ok(ChainDB(kv: kvStore nsDb, rdb: db.rdb))

# ------------------------------------------------------------------------------
# Public constructor and low level data retrieval, storage & transation frame
# ------------------------------------------------------------------------------

proc newLegacyPersistentCoreDbRef*(path: string): CoreDbRef =
  # when running `newChainDB(path)`. converted to a `Defect`.
  let backend = newChainDB(path).valueOr:
    let msg = "DB initialisation : " & error
    raise (ref ResultDefect)(msg: msg)

  var nsMap = initTable[DbNamespace, TrieDatabaseRef]()

  for ns in getNamespaces():
    let namespace = backend.withNamespace($ns).valueOr:
      let msg = "DB initialisation : " & error
      raise (ref ResultDefect)(msg: msg)
    nsMap[ns] = trieDB(namespace)

  proc done() =
    backend.rdb.close()

  LegaPersDbRef(rdb: backend.rdb).init(LegacyDbPersistent, trieDB(backend), nsMap, done)

# ------------------------------------------------------------------------------
# Public helper for direct backend access
# ------------------------------------------------------------------------------

proc toRocksStoreRef*(db: CoreDbBackendRef): RocksStoreRef =
  if db.parent.dbType == LegacyDbPersistent:
    return db.parent.LegaPersDbRef.rdb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

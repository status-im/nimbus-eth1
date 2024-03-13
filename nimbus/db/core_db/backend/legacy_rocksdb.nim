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
    rdb: RocksStoreRef
    nsMap: Table[DBKeyKind, RocksNamespaceRef]

proc toNamespace(k: DBKeyKind): string =
  $ord(k)

template isDefault(k: DBKeyKind): bool =
  k == DBKeyKind.default

proc getDbKeyKinds(): seq[DBKeyKind] =
  var namespaces = newSeq[DBKeyKind]()
  for k in DBKeyKind.items():
    namespaces.add(k)
  namespaces

const
  dbKindLow = byte ord(DBKeyKind.low()) + 1 # add one to skip default
  dbKindHigh = byte ord(DBKeyKind.high())

proc toDbKeyKind(key: openArray[byte]): DBKeyKind {.inline.} =
  let prefixByte = key[0]
  if prefixByte >= dbKindLow and prefixByte <= dbKindHigh:
    DBKeyKind(prefixByte)
  else:
    default

proc get(db: ChainDB, key: openArray[byte]): seq[byte] =
  let kind = key.toDbKeyKind()

  var res: seq[byte]
  proc onData(data: openArray[byte]) = res = @data

  if kind.isDefault():
    discard db.rdb.get(key, onData).expect("working database")
    return res

  let ns = db.nsMap.getOrDefault(kind)
  if ns.contains(key).expect("working database"):
    discard ns.get(key, onData).expect("working database")
  else:
    discard db.rdb.get(key, onData).expect("working database")

  res

proc put(db: ChainDB, key, value: openArray[byte]) =
  let kind = key.toDbKeyKind()
  if kind.isDefault():
    db.rdb.put(key, value).expect("working database")
  else:
    db.nsMap.getOrDefault(kind).put(key, value).expect("working database")

proc contains(db: ChainDB, key: openArray[byte]): bool =
  let kind = key.toDbKeyKind()

  let r1 = db.rdb.contains(key).expect("working database")
  if kind.isDefault():
    return r1

  let r2 = db.nsMap.getOrDefault(kind).contains(key).expect("working database")
  r1 or r2

proc del(db: ChainDB, key: openArray[byte]): bool =
  let kind = key.toDbKeyKind()

  let r1 = db.rdb.del(key).expect("working database")
  if kind.isDefault():
    return r1

  let r2 = db.nsMap.getOrDefault(kind).del(key).expect("working database")
  r1 or r2

proc newChainDB(path: string): KvResult[ChainDB] =
  let dbKeyKinds = getDbKeyKinds()

  let rdb = RocksStoreRef.init(
      path,
      "nimbus",
      namespaces = dbKeyKinds.mapIt(it.toNamespace())).valueOr:
    return err(error)

  var nsMap = initTable[DBKeyKind, RocksNamespaceRef]()
  for k in dbKeyKinds:
    let namespace = rdb.openNamespace(k.toNamespace()).valueOr:
      let msg = "DB initialisation : " & error
      raise (ref ResultDefect)(msg: msg)
    nsMap[k] = namespace

  ok(ChainDB(rdb: rdb, nsMap: nsMap))

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

  LegaPersDbRef(rdb: backend.rdb).init(LegacyDbPersistent, trieDB(backend), done)

# ------------------------------------------------------------------------------
# Public helper for direct backend access
# ------------------------------------------------------------------------------

proc toRocksStoreRef*(db: CoreDbBackendRef): RocksStoreRef =
  if db.parent.dbType == LegacyDbPersistent:
    return db.parent.LegaPersDbRef.rdb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

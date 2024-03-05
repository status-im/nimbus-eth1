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
  std/[os, sequtils],
  stew/results,
  rocksdb,
  eth/db/kvstore

export kvstore

const maxOpenFiles = 512

type
  RocksStoreRef* = ref object of RootObj
    db: RocksDbReadWriteRef

  RocksNamespaceRef* = ref object of RootObj
    colFamily: ColFamilyReadWrite

# ------------------------------------------------------------------------------
# RocksStoreRef procs
# ------------------------------------------------------------------------------

proc db*(store: RocksStoreRef): RocksDbReadWriteRef =
  store.db

proc get*(
    store: RocksStoreRef,
    key: openArray[byte],
    onData: kvstore.DataProc): KvResult[bool] =
  store.db.get(key, onData)

proc find*(
    store: RocksStoreRef,
    prefix: openArray[byte],
    onFind: kvstore.KeyValueProc): KvResult[int] =
  raiseAssert "Unimplemented"

proc put*(store: RocksStoreRef, key, value: openArray[byte]): KvResult[void] =
  store.db.put(key, value)

proc contains*(store: RocksStoreRef, key: openArray[byte]): KvResult[bool] =
  store.db.keyExists(key)

proc del*(store: RocksStoreRef, key: openArray[byte]): KvResult[bool] =

  let exists = ? store.db.keyExists(key)
  if not exists:
    return ok(false)

  let res = store.db.delete(key)
  if res.isErr():
    return err(res.error())

  ok(true)

proc clear*(store: RocksStoreRef): KvResult[bool] =
  raiseAssert "Unimplemented"

proc close*(store: RocksStoreRef) =
  store.db.close()

proc init*(
    T: type RocksStoreRef,
    basePath: string,
    name: string,
    namespaces = @["default"]): KvResult[T] =

  let dataDir = basePath / name / "data"

  try:
    createDir(dataDir)
  except OSError, IOError:
    return err("RocksStoreRef: cannot create database directory")

  let dbOpts = defaultDbOptions()
  dbOpts.setMaxOpenFiles(maxOpenFiles)

  let db = ? openRocksDb(dataDir, dbOpts,
      columnFamilies = namespaces.mapIt(initColFamilyDescriptor(it)))
  ok(T(db: db))

# ------------------------------------------------------------------------------
# RocksNamespaceRef procs
# ------------------------------------------------------------------------------

proc name*(store: RocksNamespaceRef): string =
  store.colFamily.name

proc get*(
    ns: RocksNamespaceRef,
    key: openArray[byte],
    onData: kvstore.DataProc): KvResult[bool] =
  ns.colFamily.get(key, onData)

proc find*(
    ns: RocksNamespaceRef,
    prefix: openArray[byte],
    onFind: kvstore.KeyValueProc): KvResult[int] =
  raiseAssert "Unimplemented"

proc put*(ns: RocksNamespaceRef, key, value: openArray[byte]): KvResult[void] =
  ns.colFamily.put(key, value)

proc contains*(ns: RocksNamespaceRef, key: openArray[byte]): KvResult[bool] =
  ns.colFamily.keyExists(key)

proc del*(ns: RocksNamespaceRef, key: openArray[byte]): KvResult[bool] =
  let exists = ? ns.colFamily.keyExists(key)
  if not exists:
    return ok(false)

  let res = ns.colFamily.delete(key)
  if res.isErr():
    return err(res.error())

  ok(true)

proc clear*(ns: RocksNamespaceRef): KvResult[bool] =
  raiseAssert "Unimplemented"

proc close*(ns: RocksNamespaceRef) =
  # To close the database, call close on RocksStoreRef.
  raiseAssert "Unimplemented"

proc openNamespace*(
    store: RocksStoreRef,
    name: string): KvResult[RocksNamespaceRef] =
  doAssert not store.db.isClosed()

  let cf = ? store.db.withColFamily(name)
  ok(RocksNamespaceRef(colFamily: cf))

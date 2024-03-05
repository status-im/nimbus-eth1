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
    db: RocksDbRef
    backupEngine: BackupEngineRef
    readOnly: bool

  RocksNamespaceRef* = ref object of RootObj
    case readOnly: bool
    of true:
      cfReadOnly: ColFamilyReadOnly
    of false:
      cfReadWrite: ColFamilyReadWrite

# ------------------------------------------------------------------------------
# RocksStoreRef functions
# ------------------------------------------------------------------------------

proc readOnly*(store: RocksStoreRef): bool =
  store.readOnly

proc readOnlyDb*(store: RocksStoreRef): RocksDbReadOnlyRef =
  doAssert store.readOnly
  store.db.RocksDbReadOnlyRef

proc readWriteDb*(store: RocksStoreRef): RocksDbReadWriteRef =
  doAssert not store.readOnly
  store.db.RocksDbReadWriteRef

template validateCanWriteAndGet(store: RocksStoreRef): RocksDbReadWriteRef =
  if store.readOnly:
    raiseAssert "Unimplemented"
  store.db.RocksDbReadWriteRef

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
  store.validateCanWriteAndGet().put(key, value)

proc contains*(store: RocksStoreRef, key: openArray[byte]): KvResult[bool] =
  store.db.keyExists(key)

proc del*(store: RocksStoreRef, key: openArray[byte]): KvResult[bool] =
  let db = store.validateCanWriteAndGet()

  let exists = ? db.keyExists(key)
  if not exists:
    return ok(false)

  let res = db.delete(key)
  if res.isErr():
    return err(res.error())

  ok(true)

proc clear*(store: RocksStoreRef): KvResult[bool] =
  raiseAssert "Unimplemented"

proc close*(store: RocksStoreRef) =
  store.db.close()
  store.backupEngine.close()

proc init*(
    T: type RocksStoreRef,
    basePath: string,
    name: string,
    readOnly = false,
    namespaces = @["default"]): KvResult[T] =

  let
    dataDir = basePath / name / "data"
    backupsDir = basePath / name / "backups"

  try:
    createDir(dataDir)
    createDir(backupsDir)
  except OSError, IOError:
    return err("RocksStoreRef: cannot create database directory")

  let backupEngine = ? openBackupEngine(backupsDir)

  let dbOpts = defaultDbOptions()
  dbOpts.setMaxOpenFiles(maxOpenFiles)

  if readOnly:
    let readOnlyDb = ? openRocksDbReadOnly(dataDir, dbOpts,
        columnFamilies = namespaces.mapIt(initColFamilyDescriptor(it)))
    ok(T(db: readOnlyDb, backupEngine: backupEngine, readOnly: true))
  else:
    let readWriteDb = ? openRocksDb(dataDir, dbOpts,
        columnFamilies = namespaces.mapIt(initColFamilyDescriptor(it)))
    ok(T(db: readWriteDb, backupEngine: backupEngine, readOnly: false))

# ------------------------------------------------------------------------------
# RocksNamespaceRef functions
# ------------------------------------------------------------------------------

proc readOnly*(ns: RocksNamespaceRef): bool =
  ns.readOnly

proc get*(
    ns: RocksNamespaceRef,
    key: openArray[byte],
    onData: kvstore.DataProc): KvResult[bool] =
  if ns.readOnly:
    ns.cfReadOnly.get(key, onData)
  else:
    ns.cfReadWrite.get(key, onData)

proc find*(
    ns: RocksNamespaceRef,
    prefix: openArray[byte],
    onFind: kvstore.KeyValueProc): KvResult[int] =
  raiseAssert "Unimplemented"

proc put*(ns: RocksNamespaceRef, key, value: openArray[byte]): KvResult[void] =
  if ns.readOnly:
    raiseAssert "Unimplemented"

  ns.cfReadWrite.put(key, value)

proc contains*(ns: RocksNamespaceRef, key: openArray[byte]): KvResult[bool] =
  if ns.readOnly:
    ns.cfReadOnly.keyExists(key)
  else:
    ns.cfReadWrite.keyExists(key)

proc del*(ns: RocksNamespaceRef, key: openArray[byte]): KvResult[bool] =
  if ns.readOnly:
    raiseAssert "Unimplemented"

  let exists = ? ns.cfReadWrite.keyExists(key)
  if not exists:
    return ok(false)

  let res = ns.cfReadWrite.delete(key)
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

  if store.readOnly:
    doAssert store.db of RocksDbReadOnlyRef
    let cf = ? store.db.RocksDbReadOnlyRef.withColFamily(name)
    ok(RocksNamespaceRef(readOnly: true, cfReadOnly: cf))
  else:
    doAssert store.db of RocksDbReadWriteRef
    let cf = ? store.db.RocksDbReadWriteRef.withColFamily(name)
    ok(RocksNamespaceRef(readOnly: false, cfReadWrite: cf))

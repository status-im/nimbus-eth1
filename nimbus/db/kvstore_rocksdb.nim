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
  std/os,
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

proc get*(store: RocksStoreRef, key: openArray[byte], onData: kvstore.DataProc): KvResult[bool] =
  store.db.get(key, onData)

proc find*(store: RocksStoreRef, prefix: openArray[byte], onFind: kvstore.KeyValueProc): KvResult[int] =
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
    readOnly = false): KvResult[T] =

  let
    dataDir = basePath / name / "data"
    backupsDir = basePath / name / "backups"

  try:
    createDir(dataDir)
    createDir(backupsDir)
  except OSError, IOError:
    return err("rocksdb: cannot create database directory")

  let backupEngine = ? openBackupEngine(backupsDir)

  let dbOpts = defaultDbOptions()
  dbOpts.setMaxOpenFiles(maxOpenFiles)

  if readOnly:
    let readOnlyDb = ? openRocksDbReadOnly(dataDir, dbOpts)
    ok(T(db: readOnlyDb, backupEngine: backupEngine, readOnly: true))
  else:
    let readWriteDb = ? openRocksDb(dataDir, dbOpts)
    ok(T(db: readWriteDb, backupEngine: backupEngine, readOnly: false))

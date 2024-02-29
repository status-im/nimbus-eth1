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

export results, kvstore

const maxOpenFiles = 512

type
  RocksStoreRef* = ref object of RootObj
    dbOpts*: DbOptionsRef
    store*: RocksDbRef
    tmpDir*: string
    backupEngine: BackupEngineRef

template validateCanWrite(db: RocksStoreRef) =
  if not (db.store of RocksDbReadWriteRef):
    raiseAssert "Unimplemented"

proc get*(db: RocksStoreRef, key: openArray[byte], onData: kvstore.DataProc): KvResult[bool] =
  db.store.get(key, onData)

proc find*(db: RocksStoreRef, prefix: openArray[byte], onFind: kvstore.KeyValueProc): KvResult[int] =
  raiseAssert "Unimplemented"

proc put*(db: RocksStoreRef, key, value: openArray[byte]): KvResult[void] =
  db.validateCanWrite()
  db.store.RocksDbReadWriteRef.put(key, value)

proc contains*(db: RocksStoreRef, key: openArray[byte]): KvResult[bool] =
  db.store.keyExists(key)

proc del*(db: RocksStoreRef, key: openArray[byte]): KvResult[bool] =
  db.validateCanWrite()
  let db = db.store.RocksDbReadWriteRef

  let exists = ? db.keyExists(key)
  if not exists:
    return ok(false)

  let res = db.delete(key)
  if res.isErr():
    return err(res.error())

  ok(true)

proc clear*(db: RocksStoreRef): KvResult[bool] =
  raiseAssert "Unimplemented"

proc close*(db: RocksStoreRef) =
  db.store.close()
  db.dbOpts.close()
  db.backupEngine.close()

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
    let readOnlyStore = ? openRocksDbReadOnly(dataDir, dbOpts)
    ok(T(dbOpts: dbOpts, store: readOnlyStore, backupEngine: backupEngine))
  else:
    let readWriteStore = ? openRocksDb(dataDir, dbOpts)
    ok(T(dbOpts: dbOpts, store: readWriteStore, backupEngine: backupEngine))

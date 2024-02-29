# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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

template canWrite(db: RocksStoreRef): bool =
  (db.store of RocksDbReadWriteRef)

template validateCanWrite(db: RocksStoreRef) =
  if not db.canWrite():
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

  let existsRes = db.keyExists(key)
  if existsRes.isErr() or existsRes.get() == false:
    return existsRes

  let delRes = db.delete(key)
  if delRes.isErr():
    return err(delRes.error())

  ok(true)

proc clear*(db: RocksStoreRef): KvResult[bool] =
  raiseAssert "Unimplemented"

proc close*(db: RocksStoreRef) =
  db.store.close()

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

  let backupRes = openBackupEngine(backupsDir)
  if backupRes.isErr():
    return err(backupRes.error())

  let dbOpts = defaultDbOptions()
  dbOpts.setMaxOpenFiles(maxOpenFiles)

  if readOnly:
    let res = openRocksDbReadOnly(dataDir, dbOpts)
    if res.isErr():
      return err(res.error())
    ok(T(dbOpts: dbOpts, store: res.get(), backupEngine: backupRes.get()))
  else:
    let res = openRocksDb(dataDir, dbOpts)
    if res.isErr():
      return err(res.error())
    ok(T(dbOpts: dbOpts, store: res.get(), backupEngine: backupRes.get()))

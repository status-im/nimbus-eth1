import os, rocksdb, ranges
import ../storage_types

type
  RocksChainDB* = object
    store: RocksDBInstance

  ChainDB* = RocksChainDB

proc initChainDB*(basePath: string): ChainDB =
  let
    dataDir = basePath / "data"
    backupsDir = basePath / "backups"

  createDir(dataDir)
  createDir(backupsDir)

  let s = result.store.init(dataDir, backupsDir)
  if not s.ok: raiseStorageInitError()

proc get*(db: ChainDB, key: DbKey): ByteRange =
  let s = db.store.getBytes(key.toOpenArray)
  if not s.ok: raiseKeyReadError(key)
  return s.value.toRange

proc put*(db: var ChainDB, key: DbKey, value: ByteRange) =
  let s = db.store.put(key.toOpenArray, value.toOpenArray)
  if not s.ok: raiseKeyWriteError(key)

proc contains*(db: ChainDB, key: DbKey): bool =
  let s = db.store.contains(key.toOpenArray)
  if not s.ok: raiseKeySearchError(key)
  return s.value

proc del*(db: var ChainDB, key: DbKey) =
  let s = db.store.del(key.toOpenArray)
  if not s.ok: raiseKeyDeletionError(key)

proc close*(db: var ChainDB) =
  db.store.close


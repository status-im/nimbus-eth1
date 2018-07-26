import os, rocksdb, ranges
import ../storage_types

type
  RocksChainDB* = ref object of RootObj
    store: RocksDBInstance

  ChainDB* = RocksChainDB

proc newChainDB*(basePath: string): ChainDB =
  result.new()
  let
    dataDir = basePath / "data"
    backupsDir = basePath / "backups"

  createDir(dataDir)
  createDir(backupsDir)

  let s = result.store.init(dataDir, backupsDir)
  if not s.ok: raiseStorageInitError()

proc get*(db: ChainDB, key: openarray[byte]): seq[byte] =
  let s = db.store.getBytes(key)
  if not s.ok: raiseKeyReadError(key)
  return s.value

proc put*(db: ChainDB, key, value: openarray[byte]) =
  let s = db.store.put(key, value)
  if not s.ok: raiseKeyWriteError(key)

proc contains*(db: ChainDB, key: openarray[byte]): bool =
  let s = db.store.contains(key)
  if not s.ok: raiseKeySearchError(key)
  return s.value

proc del*(db: ChainDB, key: openarray[byte]) =
  let s = db.store.del(key)
  if not s.ok: raiseKeyDeletionError(key)

proc close*(db: ChainDB) =
  db.store.close

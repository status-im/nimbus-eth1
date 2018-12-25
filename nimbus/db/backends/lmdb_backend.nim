import os, ranges, eth_trie/[defs, db_tracing]
import ../storage_types

when defined(windows):
  const Lib = "lmdb.dll"
elif defined(macos):
  const Lib = "liblmdb.dylib"
else:
  const Lib = "liblmdb.so"

const
  MDB_NOSUBDIR = 0x4000
  MDB_NOTFOUND = -30798
  LMDB_MAP_SIZE = 1024 * 1024 * 1024 * 10  # 10TB enough?

type
  MDB_Env = distinct pointer
  MDB_Txn = distinct pointer
  MDB_Dbi = distinct cuint

  MDB_val = object
    mv_size: csize
    mv_data: pointer

# this is only a subset of LMDB API needed in nimbus
proc mdb_env_create(env: var MDB_Env): cint {.cdecl, dynlib: Lib, importc: "mdb_env_create".}
proc mdb_env_open(env: MDB_Env, path: cstring, flags: cuint, mode: cint): cint {.cdecl, dynlib: Lib, importc: "mdb_env_open".}
proc mdb_txn_begin(env: MDB_Env, parent: MDB_Txn, flags: cuint, txn: var MDB_Txn): cint {.cdecl, dynlib: Lib, importc: "mdb_txn_begin".}
proc mdb_txn_commit(txn: MDB_Txn): cint {.cdecl, dynlib: Lib, importc: "mdb_txn_commit".}
proc mdb_dbi_open(txn: MDB_Txn, name: cstring, flags: cuint, dbi: var MDB_Dbi): cint {.cdecl, dynlib: Lib, importc: "mdb_dbi_open".}
proc mdb_dbi_close(env: MDB_Env, dbi: MDB_Dbi) {.cdecl, dynlib: Lib, importc: "mdb_dbi_close".}
proc mdb_env_close(env: MDB_Env) {.cdecl, dynlib: Lib, importc: "mdb_env_close".}

proc mdb_get(txn: MDB_Txn, dbi: MDB_Dbi, key: var MDB_val, data: var MDB_val): cint {.cdecl, dynlib: Lib, importc: "mdb_get".}
proc mdb_del(txn: MDB_Txn, dbi: MDB_Dbi, key: var MDB_val, data: ptr MDB_val): cint {.cdecl, dynlib: Lib, importc: "mdb_del".}
proc mdb_put(txn: MDB_Txn, dbi: MDB_Dbi, key: var MDB_val, data: var MDB_val, flags: cuint): cint {.cdecl, dynlib: Lib, importc: "mdb_put".}

proc mdb_env_set_mapsize(env: MDB_Env, size: uint64): cint {.cdecl, dynlib: Lib, importc: "mdb_env_set_mapsize".}

type
  LmdbChainDB* = ref object of RootObj
    env: MDB_Env
    txn: MDB_Txn
    dbi: MDB_Dbi
    manualCommit: bool

  ChainDB* = LmdbChainDB

# call txBegin and txCommit if you want to disable auto-commit
proc txBegin*(db: ChainDB, manualCommit = true): bool =
  result = true
  if manualCommit:
    db.manualCommit = true
  else:
    if db.manualCommit: return
  result = mdb_txn_begin(db.env, MDB_Txn(nil), 0, db.txn) == 0
  result = result and mdb_dbi_open(db.txn, nil, 0, db.dbi) == 0

proc txCommit*(db: ChainDB, manualCommit = true): bool =
  result = true
  if manualCommit:
    db.manualCommit = false
  else:
    if db.manualCommit: return
  result = mdb_txn_commit(db.txn) == 0
  mdb_dbi_close(db.env, db.dbi)

proc toMdbVal(val: openArray[byte]): MDB_Val =
  result.mv_size = val.len
  result.mv_data = unsafeAddr val[0]

proc get*(db: ChainDB, key: openarray[byte]): seq[byte] =
  if key.len == 0: return
  var
    dbKey = toMdbVal(key)
    dbVal: MDB_val

  if not db.txBegin(false):
    raiseKeyReadError(key)

  var errCode = mdb_get(db.txn, db.dbi, dbKey, dbVal)

  if not(errCode == 0 or errCode == MDB_NOTFOUND):
    raiseKeyReadError(key)

  if dbVal.mv_size > 0 and errCode == 0:
    result = newSeq[byte](dbVal.mv_size.int)
    copyMem(result[0].addr, dbVal.mv_data, result.len)
  else:
    result = @[]

  traceGet key, result
  if not db.txCommit(false):
    raiseKeyReadError(key)

proc put*(db: ChainDB, key, value: openarray[byte]) =
  tracePut key, value
  if key.len == 0 or value.len == 0: return
  var
    dbKey = toMdbVal(key)
    dbVal = toMdbVal(value)

  if not db.txBegin(false):
    raiseKeyWriteError(key)

  var ok = mdb_put(db.txn, db.dbi, dbKey, dbVal, 0) == 0
  if not ok:
    raiseKeyWriteError(key)

  if not db.txCommit(false):
    raiseKeyWriteError(key)

proc contains*(db: ChainDB, key: openarray[byte]): bool =
  if key.len == 0: return
  var
    dbKey = toMdbVal(key)
    dbVal: MDB_val

  if not db.txBegin(false):
    raiseKeySearchError(key)

  result = mdb_get(db.txn, db.dbi, dbKey, dbVal) == 0

  if not db.txCommit(false):
    raiseKeySearchError(key)

proc del*(db: ChainDB, key: openarray[byte]) =
  traceDel key
  if key.len == 0: return
  var
    dbKey = toMdbVal(key)

  if not db.txBegin(false):
    raiseKeyDeletionError(key)

  var errCode = mdb_del(db.txn, db.dbi, dbKey, nil)
  if not(errCode == 0 or errCode == MDB_NOTFOUND):
    raiseKeyDeletionError(key)

  if not db.txCommit(false):
    raiseKeyDeletionError(key)

proc close*(db: ChainDB) =
  mdb_env_close(db.env)

proc newChainDB*(basePath: string): ChainDB =
  result.new()

  let dataDir = basePath / "nimbus.db"
  var ok = mdb_env_create(result.env) == 0
  if not ok: raiseStorageInitError()

  ok = mdb_env_set_mapsize(result.env, LMDB_MAP_SIZE) == 0
  if not ok: raiseStorageInitError()

  # file mode ignored on windows
  ok = mdb_env_open(result.env, dataDir, MDB_NOSUBDIR, 0o664) == 0
  if not ok: raiseStorageInitError()

  result.put(emptyRlpHash.data, emptyRlp)

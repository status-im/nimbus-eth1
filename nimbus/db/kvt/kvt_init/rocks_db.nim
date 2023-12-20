# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocksdb backend for Kvt DB
## ==========================
##
## The iterators provided here are currently available only by direct
## backend access
## ::
##   import
##     kvt/kvt_init,
##     kvt/kvt_init/kvt_rocksdb
##
##   let rc = KvtDb.init(BackendRocksDB, "/var/tmp")
##   if rc.isOk:
##     let be = rc.value.to(RdbBackendRef)
##     for (n, key, vtx) in be.walkVtx:
##       ...
##
{.push raises: [].}

import
  chronicles,
  eth/common,
  rocksdb,
  results,
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  ./init_common,
  ./rocks_db/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk]

logScope:
  topics = "kvt-backend"

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database

  RdbPutHdlRef = ref object of TypedPutHdlRef
    tab: Table[Blob,Blob]     ## Transaction cache

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

  # ----------

  maxOpenFiles = 512          ## Rocks DB setup, open files limit

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "RocksDB " & info


proc newSession(db: RdbBackendRef): RdbPutHdlRef =
  new result
  result.TypedPutHdlRef.beginSession db

proc getSession(hdl: PutHdlRef; db: RdbBackendRef): RdbPutHdlRef =
  hdl.TypedPutHdlRef.verifySession db
  hdl.RdbPutHdlRef

proc endSession(hdl: PutHdlRef; db: RdbBackendRef): RdbPutHdlRef =
  hdl.TypedPutHdlRef.finishSession db
  hdl.RdbPutHdlRef

# ------------------------------------------------------------------------------
# Private functions: interface
# ------------------------------------------------------------------------------

proc getKvpFn(db: RdbBackendRef): GetKvpFn =
  result =
    proc(key: openArray[byte]): Result[Blob,KvtError] =
      if key.len == 0:
        return err(KeyInvalid)
      let rc = db.rdb.get key
      if rc.isErr:
        debug logTxt "getKvpFn() failed", key,
          error=rc.error[0], info=rc.error[1]
        return err(rc.error[0])

      # Decode data record
      if 0 < rc.value.len:
        return ok(rc.value)

      err(GetNotFound)

# -------------

proc putBegFn(db: RdbBackendRef): PutBegFn =
  result =
    proc(): PutHdlRef =
      db.newSession()

proc putKvpFn(db: RdbBackendRef): PutKvpFn =
  result =
    proc(hdl: PutHdlRef; kvps: openArray[(Blob,Blob)]) =
      let hdl = hdl.getSession db
      if hdl.error == KvtError(0):
        for (k,v) in kvps:
          if k.isValid:
            hdl.tab[k] = v
          else:
            hdl.error = KeyInvalid

proc putEndFn(db: RdbBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,KvtError] =
      let hdl = hdl.endSession db
      if hdl.error != KvtError(0):
        debug logTxt "putEndFn: key/value failed", error=hdl.error
        return err(hdl.error)
      let rc = db.rdb.put hdl.tab
      if rc.isErr:
        when extraTraceMessages:
          debug logTxt "putEndFn: failed",
            error=rc.error[0], info=rc.error[1]
        return err(rc.error[0])
      ok()


proc closeFn(db: RdbBackendRef): CloseFn =
  result =
    proc(flush: bool) =
      db.rdb.destroy(flush)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rocksDbBackend*(
    path: string;
      ): Result[BackendRef,KvtError] =
  let db = RdbBackendRef(
    beKind: BackendRocksDB)

  # Initialise RocksDB
  block:
    let rc = db.rdb.init(path, maxOpenFiles)
    if rc.isErr:
      when extraTraceMessages:
        trace logTxt "constructor failed",
           error=rc.error[0], info=rc.error[1]
        return err(rc.error[0])

  db.getKvpFn = getKvpFn db

  db.putBegFn = putBegFn db
  db.putKvpFn = putKvpFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

  ok db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: RdbBackendRef;
      ): tuple[key: Blob, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  for (k,v) in be.rdb.walk:
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

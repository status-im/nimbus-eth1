# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  rocksdb,
  results,
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  ./init_common,
  ./rocks_db/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk]

export rdb_desc

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database

  RdbPutHdlRef = ref object of TypedPutHdlRef
    session*: SharedWriteBatchRef

logScope:
  topics = "kvt-backend"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc newSession(db: RdbBackendRef, session: SharedWriteBatchRef): RdbPutHdlRef =
  result = RdbPutHdlRef(session: session)
  result.TypedPutHdlRef.beginSession db

proc getSession(hdl: PutHdlRef; db: RdbBackendRef): RdbPutHdlRef =
  hdl.TypedPutHdlRef.verifySession db
  hdl.RdbPutHdlRef

proc endSession(hdl: PutHdlRef; db: RdbBackendRef): RdbPutHdlRef =
  hdl.TypedPutHdlRef.finishSession db
  hdl.RdbPutHdlRef

# ------------------------------------------------------------------------------
# Private functions: standard interface
# ------------------------------------------------------------------------------

proc getKvpFn(db: RdbBackendRef): GetKvpFn =
  result =
    proc(key: openArray[byte]): Result[seq[byte],KvtError] =

      # Get data record
      var data = db.rdb.get(key).valueOr:
        when extraTraceMessages:
          debug "getKvpFn() failed", key, error=error[0], info=error[1]
        return err(error[0])

      # Return if non-empty
      if 0 < data.len:
        return ok(move(data))

      err(GetNotFound)

proc lenKvpFn(db: RdbBackendRef): LenKvpFn =
  result =
    proc(key: openArray[byte]): Result[int,KvtError] =

      # Get data record
      var len = db.rdb.len(key).valueOr:
        when extraTraceMessages:
          debug "lenKvpFn() failed", key, error=error[0], info=error[1]
        return err(error[0])

      # Return if non-empty
      if 0 < len:
        return ok(len)

      err(GetNotFound)

# -------------

proc putBegFn(db: RdbBackendRef): PutBegFn =
  result =
    proc(): Result[PutHdlRef,KvtError] =
      ok db.newSession(db.rdb.begin())


proc putKvpFn(db: RdbBackendRef): PutKvpFn =
  result =
    proc(hdl: PutHdlRef; k, v: openArray[byte]) =
      let hdl = hdl.getSession db
      if hdl.error == KvtError(0):

        # Collect batch session arguments
        db.rdb.put(hdl.session, k, v).isOkOr:
          hdl.error = error[0]
          hdl.info = error[1]
          return


proc putEndFn(db: RdbBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,KvtError] =
      let hdl = hdl.endSession db
      if hdl.error != KvtError(0):
        when extraTraceMessages:
          debug "putEndFn: failed", error=hdl.error, info=hdl.info
        db.rdb.rollback(hdl.session)
        return err(hdl.error)

      # Commit session
      db.rdb.commit(hdl.session).isOkOr:
        when extraTraceMessages:
          trace "putEndFn: failed", error=($error[0]), info=error[1]
          return err(error[0])
      ok()


proc closeFn(db: RdbBackendRef): CloseFn =
  result =
    proc(eradicate: bool) =
      db.rdb.destroy(eradicate)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rocksDbKvtBackend*(baseDb: RocksDbInstanceRef): BackendRef =
  let db = RdbBackendRef(beKind: BackendRocksDB)

  # Initialise RocksDB
  db.rdb.init(baseDb)

  db.getKvpFn = getKvpFn db
  db.lenKvpFn = lenKvpFn db

  db.putBegFn = putBegFn db
  db.putKvpFn = putKvpFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

  db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: RdbBackendRef;
      ): tuple[key: seq[byte], data: seq[byte]] =
  ## Walk over all key-value pairs of the database.
  ##
  for (k,v) in be.rdb.walk:
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

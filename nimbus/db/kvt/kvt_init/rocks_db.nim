# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
{.warning: "*** importing rocks DB which needs a linker library".}

import
  eth/common,
  rocksdb,
  results,
  ../kvt_desc,
  ../kvt_desc/desc_backend,
  ./init_common,
  ./rocks_db/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk]


const
  maxOpenFiles = 512          ## Rocks DB setup, open files limit

  extraTraceMessages = false or true
    ## Enabled additional logging noise

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database

  RdbPutHdlRef = ref object of TypedPutHdlRef
    tab: Table[Blob,Blob]     ## Transaction cache

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-backend"

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

      # Get data record
      let data = db.rdb.get(key).valueOr:
        when extraTraceMessages:
          debug logTxt "getKvpFn() failed", key, error=error[0], info=error[1]
        return err(error[0])

      # Return if non-empty
      if 0 < data.len:
        return ok(data)

      err(GetNotFound)

# -------------

proc putBegFn(db: RdbBackendRef): PutBegFn =
  result =
    proc(): PutHdlRef =
      db.rdb.begin()
      db.newSession()

proc putKvpFn(db: RdbBackendRef): PutKvpFn =
  result =
    proc(hdl: PutHdlRef; kvps: openArray[(Blob,Blob)]) =
      let hdl = hdl.getSession db
      if hdl.error == KvtError(0):

        # Collect batch session arguments
        db.rdb.put(kvps).isOkOr:
          hdl.error = error[1]
          hdl.info = error[2]
          return

proc putEndFn(db: RdbBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,KvtError] =
      let hdl = hdl.endSession db
      if hdl.error != KvtError(0):
        when extraTraceMessages:
          debug logTxt "putEndFn: failed", error=hdl.error, info=hdl.info
        return err(hdl.error)

      # Commit session
      db.rdb.commit().isOkOr:
        when extraTraceMessages:
          trace logTxt "putEndFn: failed", error=($error[0]), info=error[1]
        return err(error[0])
      ok()


proc closeFn(db: RdbBackendRef): CloseFn =
  result =
    proc(flush: bool) =
      db.rdb.destroy(flush)

# --------------

proc setup(db: RdbBackendRef) =
  db.getKvpFn = getKvpFn db

  db.putBegFn = putBegFn db
  db.putKvpFn = putKvpFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rocksDbBackend*(path: string): Result[BackendRef,KvtError] =
  let db = RdbBackendRef(
    beKind: BackendRocksDB)

  # Initialise RocksDB
  db.rdb.init(path, maxOpenFiles).isOkOr:
    when extraTraceMessages:
      trace logTxt "constructor failed", error=error[0], info=error[1]
    return err(error[0])

  db.setup()
  ok db

proc rocksDbBackend*(store: ColFamilyReadWrite): Result[BackendRef,KvtError] =
  let db = RdbBackendRef(
    beKind: BackendRocksDB)
  db.rdb.init(store)
  db.setup()
  ok db

proc dup*(db: RdbBackendRef): RdbBackendRef =
  new result
  init_common.init(result[], db[])
  result.rdb = db.rdb

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

# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocksdb backend for Aristo DB
## =============================
##
## The iterators provided here are currently available only by direct
## backend access
## ::
##   import
##     aristo/aristo_init,
##     aristo/aristo_init/aristo_rocksdb
##
##   let rc = AristoDb.init(BackendRocksDB, "/var/tmp")
##   if rc.isOk:
##     let be = rc.value.to(RdbBackendRef)
##     for (n, key, vtx) in be.walkVtx:
##       ...
##
{.push raises: [].}

import
  rocksdb,
  results,
  ../aristo_desc,
  ../aristo_desc/desc_backend,
  ../aristo_blobify,
  ./init_common,
  ./rocks_db/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk],
  ../../opts

export rdb_desc

const
  extraTraceMessages = false
    ## Enabled additional logging noise

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database

  RdbPutHdlRef = ref object of TypedPutHdlRef
    session*: SharedWriteBatchRef

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-backend"

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
# Private functions: interface
# ------------------------------------------------------------------------------

proc getVtxFn(db: RdbBackendRef): GetVtxFn =
  result =
    proc(rvid: RootedVertexID, flags: set[GetVtxFlag]): Result[VertexRef,AristoError] =

      # Fetch serialised data record
      let vtx = db.rdb.getVtx(rvid, flags).valueOr:
        when extraTraceMessages:
          trace logTxt "getVtxFn() failed", rvid, error=error[0], info=error[1]
        return err(error[0])

      if vtx.isValid:
        return ok(vtx)

      err(GetVtxNotFound)

proc getKeyFn(db: RdbBackendRef): GetKeyFn =
  result =
    proc(rvid: RootedVertexID, flags: set[GetVtxFlag]): Result[(HashKey, VertexRef),AristoError] =

      # Fetch serialised data record
      let key = db.rdb.getKey(rvid, flags).valueOr:
        when extraTraceMessages:
          trace logTxt "getKeyFn: failed", rvid, error=error[0], info=error[1]
        return err(error[0])

      if (key[0].isValid or key[1].isValid):
        return ok(key)

      err(GetKeyNotFound)

proc getTuvFn(db: RdbBackendRef): GetTuvFn =
  result =
    proc(): Result[VertexID,AristoError]=

      # Fetch serialised data record.
      let data = db.rdb.getAdm(AdmTabIdTuv).valueOr:
        when extraTraceMessages:
          trace logTxt "getTuvFn: failed", error=error[0], info=error[1]
        return err(error[0])

      # Decode data record
      if data.len == 0:
        return ok VertexID(0)

      # Decode data record
      result = data.deblobify VertexID

proc getLstFn(db: RdbBackendRef): GetLstFn =
  result =
    proc(): Result[SavedState,AristoError]=

      # Fetch serialised data record.
      let data = db.rdb.getAdm(AdmTabIdLst).valueOr:
        when extraTraceMessages:
          trace logTxt "getLstFn: failed", error=error[0], info=error[1]
        return err(error[0])

      # Decode data record
      data.deblobify SavedState

# -------------

proc putBegFn(db: RdbBackendRef): PutBegFn =
  result =
    proc(): Result[PutHdlRef,AristoError] =
      ok db.newSession(db.rdb.begin())

proc putVtxFn(db: RdbBackendRef): PutVtxFn =
  result =
    proc(hdl: PutHdlRef; rvid: RootedVertexID; vtx: VertexRef, key: HashKey) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        db.rdb.putVtx(hdl.session, rvid, vtx, key).isOkOr:
          hdl.error = TypedPutHdlErrRef(
            pfx:  VtxPfx,
            vid:  error[0],
            code: error[1],
            info: error[2])

proc putTuvFn(db: RdbBackendRef): PutTuvFn =
  result =
    proc(hdl: PutHdlRef; vs: VertexID)  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        if vs.isValid:
          db.rdb.putAdm(hdl.session, AdmTabIdTuv, vs.blobify.data()).isOkOr:
            hdl.error = TypedPutHdlErrRef(
              pfx:  AdmPfx,
              aid:  AdmTabIdTuv,
              code: error[1],
              info: error[2])
            return


proc putLstFn(db: RdbBackendRef): PutLstFn =
  result =
    proc(hdl: PutHdlRef; lst: SavedState) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        let data = lst.blobify
        db.rdb.putAdm(hdl.session, AdmTabIdLst, data).isOkOr:
          hdl.error = TypedPutHdlErrRef(
            pfx:  AdmPfx,
            aid:  AdmTabIdLst,
            code: error[1],
            info: error[2])

proc putEndFn(db: RdbBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,AristoError] =
      let hdl = hdl.endSession db
      if not hdl.error.isNil:
        when extraTraceMessages:
          case hdl.error.pfx:
          of VtxPfx: trace logTxt "putEndFn: vtx/key failed",
            pfx=hdl.error.pfx, vid=hdl.error.vid, error=hdl.error.code
          of AdmPfx: trace logTxt "putEndFn: admin failed",
            pfx=AdmPfx, aid=hdl.error.aid.uint64, error=hdl.error.code
          of Oops: trace logTxt "putEndFn: oops",
            pfx=hdl.error.pfx, error=hdl.error.code
        db.rdb.rollback(hdl.session)
        return err(hdl.error.code)

      # Commit session
      db.rdb.commit(hdl.session).isOkOr:
        when extraTraceMessages:
          trace logTxt "putEndFn: failed", error=($error[0]), info=error[1]
        return err(error[0])
      ok()

proc closeFn(db: RdbBackendRef): CloseFn =
  result =
    proc(eradicate: bool) =
      db.rdb.destroy(eradicate)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rocksDbBackend*(
    opts: DbOptions;
    baseDb: RocksDbInstanceRef;
      ): BackendRef =
  let db = RdbBackendRef(beKind: BackendRocksDB)

  # Initialise RocksDB
  db.rdb.init(opts, baseDb)

  db.getVtxFn = getVtxFn db
  db.getKeyFn = getKeyFn db
  db.getTuvFn = getTuvFn db
  db.getLstFn = getLstFn db

  db.putBegFn = putBegFn db
  db.putVtxFn = putVtxFn db
  db.putTuvFn = putTuvFn db
  db.putLstFn = putLstFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

  db

proc dup*(db: RdbBackendRef): RdbBackendRef =
  ## Duplicate descriptor shell as needed for API debugging
  new result
  init_common.init(result[], db[])
  result.rdb = db.rdb

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walkVtx*(
    be: RdbBackendRef;
    kinds = {Branch, Leaf};
      ): tuple[evid: RootedVertexID, vtx: VertexRef] =
  ## Variant of `walk()` iteration over the vertex sub-table.
  for (rvid, vtx) in be.rdb.walkVtx(kinds):
    yield (rvid, vtx)

iterator walkKey*(
    be: RdbBackendRef;
      ): tuple[rvid: RootedVertexID, key: HashKey] =
  ## Variant of `walk()` iteration over the Markle hash sub-table.
  for (rvid, data) in be.rdb.walkKey:
    yield (rvid, data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

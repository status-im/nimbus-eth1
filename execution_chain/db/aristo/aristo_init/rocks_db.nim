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

proc getLstFn(db: RdbBackendRef): GetLstFn =
  result =
    proc(): Result[SavedState,AristoError]=

      # Fetch serialised data record.
      let data = db.rdb.getAdm().valueOr:
        when extraTraceMessages:
          trace logTxt "getLstFn: failed", error=error[0], info=error[1]
        return err(error[0])

      if data.len == 0:
        return ok default(SavedState)

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

proc putLstFn(db: RdbBackendRef): PutLstFn =
  result =
    proc(hdl: PutHdlRef; lst: SavedState) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        let data = lst.blobify
        db.rdb.putAdm(hdl.session, data).isOkOr:
          hdl.error = TypedPutHdlErrRef(
            pfx:  AdmPfx,
            aid:  AdmTabIdLst,
            code: error[0],
            info: error[1])

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
      ): AristoDbRef =
  let
    be = RdbBackendRef(beKind: BackendRocksDB)
    db = AristoDbRef()

  # Initialise RocksDB
  be.rdb.init(opts, baseDb)

  db.getVtxFn = getVtxFn be
  db.getKeyFn = getKeyFn be
  db.getLstFn = getLstFn be

  db.putBegFn = putBegFn be
  db.putVtxFn = putVtxFn be
  db.putLstFn = putLstFn be
  db.putEndFn = putEndFn be

  db.closeFn = closeFn be

  db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walkVtx*(
    be: RdbBackendRef;
    kinds = VertexTypes;
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

# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
{.warning: "*** importing rocks DB which needs a linker library".}

import
  eth/common,
  rocksdb,
  results,
  ../aristo_constants,
  ../aristo_desc,
  ../aristo_desc/desc_backend,
  ../aristo_blobify,
  ./init_common,
  ./rocks_db/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk],
  ../../opts

const
  extraTraceMessages = false
    ## Enabled additional logging noise

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database

  RdbPutHdlRef = ref object of TypedPutHdlRef

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-backend"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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

proc getVtxFn(db: RdbBackendRef): GetVtxFn =
  result =
    proc(vid: VertexID): Result[VertexRef,AristoError] =

      # Fetch serialised data record
      let data = db.rdb.getVtx(vid.uint64).valueOr:
        when extraTraceMessages:
          trace logTxt "getVtxFn() failed", vid, error=error[0], info=error[1]
        return err(error[0])

      # Decode data record
      if 0 < data.len:
        return data.deblobify VertexRef

      err(GetVtxNotFound)

proc getKeyFn(db: RdbBackendRef): GetKeyFn =
  result =
    proc(vid: VertexID): Result[HashKey,AristoError] =

      # Fetch serialised data record
      let data = db.rdb.getKey(vid.uint64).valueOr:
        when extraTraceMessages:
          trace logTxt "getKeyFn: failed", vid, error=error[0], info=error[1]
        return err(error[0])

      # Decode data record
      if 0 < data.len:
        let lid = HashKey.fromBytes(data).valueOr:
          return err(RdbHashKeyExpected)
        return ok lid

      err(GetKeyNotFound)

proc getIdgFn(db: RdbBackendRef): GetIdgFn =
  result =
    proc(): Result[seq[VertexID],AristoError]=

      # Fetch serialised data record.
      let data = db.rdb.getByPfx(AdmPfx, AdmTabIdIdg.uint64).valueOr:
        when extraTraceMessages:
          trace logTxt "getIdgFn: failed", error=error[0], info=error[1]
        return err(error[0])

      # Decode data record
      if data.len == 0:
        let w = EmptyVidSeq   # Must be `let`
        return ok w           # Compiler error with `ok(EmptyVidSeq)`

      # Decode data record
      data.deblobify seq[VertexID]

proc getLstFn(db: RdbBackendRef): GetLstFn =
  result =
    proc(): Result[SavedState,AristoError]=

      # Fetch serialised data record.
      let data = db.rdb.getByPfx(AdmPfx, AdmTabIdLst.uint64).valueOr:
        when extraTraceMessages:
          trace logTxt "getLstFn: failed", error=error[0], info=error[1]
        return err(error[0])

      # Decode data record
      data.deblobify SavedState

# -------------

proc putBegFn(db: RdbBackendRef): PutBegFn =
  result =
    proc(): PutHdlRef =
      db.rdb.begin()
      db.newSession()

proc putVtxFn(db: RdbBackendRef): PutVtxFn =
  result =
    proc(hdl: PutHdlRef; vrps: openArray[(VertexID,VertexRef)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:

        # Collect batch session arguments
        var batch: seq[(uint64,Blob)]
        for (vid,vtx) in vrps:
          if vtx.isValid:
            let rc = vtx.blobify()
            if rc.isErr:
              hdl.error = TypedPutHdlErrRef(
                pfx:  VtxPfx,
                vid:  vid,
                code: rc.error)
              return
            batch.add (vid.uint64, rc.value)
          else:
            batch.add (vid.uint64, EmptyBlob)

        # Stash batch session data via LRU cache
        db.rdb.putVtx(batch).isOkOr:
          hdl.error = TypedPutHdlErrRef(
            pfx:  VtxPfx,
            vid:  VertexID(error[0]),
            code: error[1],
            info: error[2])

proc putKeyFn(db: RdbBackendRef): PutKeyFn =
  result =
    proc(hdl: PutHdlRef; vkps: openArray[(VertexID,HashKey)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:

        # Collect batch session arguments
        var batch: seq[(uint64,Blob)]
        for (vid,key) in vkps:
          if key.isValid:
            batch.add (vid.uint64, @(key.data))
          else:
            batch.add (vid.uint64, EmptyBlob)

        # Stash batch session data via LRU cache
        db.rdb.putKey(batch).isOkOr:
          hdl.error = TypedPutHdlErrRef(
            pfx:  KeyPfx,
            vid:  VertexID(error[0]),
            code: error[1],
            info: error[2])

proc putIdgFn(db: RdbBackendRef): PutIdgFn =
  result =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        let data = if 0 < vs.len: vs.blobify else: EmptyBlob
        db.rdb.putByPfx(AdmPfx, @[(AdmTabIdIdg.uint64, data)]).isOkOr:
          hdl.error = TypedPutHdlErrRef(
            pfx:  AdmPfx,
            aid:  AdmTabIdIdg,
            code: error[1],
            info: error[2])

proc putLstFn(db: RdbBackendRef): PutLstFn =
  result =
    proc(hdl: PutHdlRef; lst: SavedState) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        db.rdb.putByPfx(AdmPfx, @[(AdmTabIdLst.uint64, lst.blobify)]).isOkOr:
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
          of VtxPfx, KeyPfx: trace logTxt "putEndFn: vtx/key failed",
            pfx=hdl.error.pfx, vid=hdl.error.vid, error=hdl.error.code
          of FilPfx: trace logTxt "putEndFn: filter failed",
            pfx=FilPfx, qid=hdl.error.qid, error=hdl.error.code
          of AdmPfx: trace logTxt "putEndFn: admin failed",
            pfx=AdmPfx, aid=hdl.error.aid.uint64, error=hdl.error.code
          of Oops: trace logTxt "putEndFn: oops",
            error=hdl.error.code
        return err(hdl.error.code)

      # Commit session
      db.rdb.commit().isOkOr:
        when extraTraceMessages:
          trace logTxt "putEndFn: failed", error=($error[0]), info=error[1]
        return err(error[0])
      ok()

proc guestDbFn(db: RdbBackendRef): GuestDbFn =
  result =
    proc(instance: int): Result[RootRef,AristoError] =
      let gdb = db.rdb.initGuestDb(instance).valueOr:
        when extraTraceMessages:
          trace logTxt "guestDbFn", error=error[0], info=error[1]
        return err(error[0])
      ok gdb

proc closeFn(db: RdbBackendRef): CloseFn =
  result =
    proc(flush: bool) =
      db.rdb.destroy(flush)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rocksDbBackend*(
    path: string;
    opts: DbOptions
      ): Result[BackendRef,AristoError] =
  let db = RdbBackendRef(
    beKind: BackendRocksDB)

  # Initialise RocksDB
  block:
    let rc = db.rdb.init(path, opts)
    if rc.isErr:
      when extraTraceMessages:
        trace logTxt "constructor failed",
           error=rc.error[0], info=rc.error[1]
        return err(rc.error[0])

  db.getVtxFn = getVtxFn db
  db.getKeyFn = getKeyFn db
  db.getIdgFn = getIdgFn db
  db.getLstFn = getLstFn db

  db.putBegFn = putBegFn db
  db.putVtxFn = putVtxFn db
  db.putKeyFn = putKeyFn db
  db.putIdgFn = putIdgFn db
  db.putLstFn = putLstFn db
  db.putEndFn = putEndFn db

  db.guestDbFn = guestDbFn db
  db.closeFn = closeFn db
  ok db

proc dup*(db: RdbBackendRef): RdbBackendRef =
  ## Duplicate descriptor shell as needed for API debugging
  new result
  init_common.init(result[], db[])
  result.rdb = db.rdb

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: RdbBackendRef;
      ): tuple[pfx: StorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  for w in be.rdb.walk:
    yield w

iterator walkVtx*(
    be: RdbBackendRef;
      ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Variant of `walk()` iteration over the vertex sub-table.
  for (xid, data) in be.rdb.walk VtxPfx:
    let rc = data.deblobify VertexRef
    if rc.isOk:
      yield (VertexID(xid), rc.value)

iterator walkKey*(
    be: RdbBackendRef;
      ): tuple[vid: VertexID, key: HashKey] =
  ## Variant of `walk()` iteration over the Markle hash sub-table.
  for (xid, data) in be.rdb.walk KeyPfx:
    let lid = HashKey.fromBytes(data).valueOr:
      continue
    yield (VertexID(xid), lid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

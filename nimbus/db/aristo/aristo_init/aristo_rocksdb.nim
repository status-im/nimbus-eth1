# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  chronicles,
  eth/common,
  rocksdb,
  stew/results,
  ../aristo_constants,
  ../aristo_desc,
  ../aristo_desc/aristo_types_backend,
  ../aristo_transcode,
  ./aristo_init_common,
  ./aristo_rocksdb/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk]

logScope:
  topics = "aristo-backend"

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database

  RdbPutHdlRef = ref object of TypedPutHdlRef
    cache: RdbTabs            ## Tranaction cache

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

proc getVtxFn(db: RdbBackendRef): GetVtxFn =
  result =
    proc(vid: VertexID): Result[VertexRef,AristoError] =

      # Fetch serialised data record
      let rc = db.rdb.get vid.toOpenArray(VtxPfx)
      if rc.isErr:
        debug logTxt "getVtxFn() failed", vid,
          error=rc.error[0], info=rc.error[1]
        return err(rc.error[0])

      # Decode data record
      if 0 < rc.value.len:
        return rc.value.deblobify VertexRef

      err(GetVtxNotFound)

proc getKeyFn(db: RdbBackendRef): GetKeyFn =
  result =
    proc(vid: VertexID): Result[HashKey,AristoError] =

      # Fetch serialised data record
      let rc = db.rdb.get vid.toOpenArray(KeyPfx)
      if rc.isErr:
        debug logTxt "getKeyFn: failed", vid,
          error=rc.error[0], info=rc.error[1]
        return err(rc.error[0])

      # Decode data record
      if 0 < rc.value.len:
        var key: HashKey
        if key.init rc.value:
          return ok key

      err(GetKeyNotFound)

proc getIdgFn(db: RdbBackendRef): GetIdgFn =
  result =
    proc(): Result[seq[VertexID],AristoError]=

      # Fetch serialised data record
      let rc = db.rdb.get VertexID(0).toOpenArray(IdgPfx)
      if rc.isErr:
        debug logTxt "getIdgFn: failed", error=rc.error[1]
        return err(rc.error[0])

      if rc.value.len == 0:
        let w = EmptyVidSeq
        return ok w

      # Decode data record
      rc.value.deblobify seq[VertexID]

# -------------

proc putBegFn(db: RdbBackendRef): PutBegFn =
  result =
    proc(): PutHdlRef =
      db.newSession()


proc putVtxFn(db: RdbBackendRef): PutVtxFn =
  result =
    proc(hdl: PutHdlRef; vrps: openArray[(VertexID,VertexRef)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        for (vid,vtx) in vrps:
          if vtx.isValid:
            let rc = vtx.blobify
            if rc.isErr:
              hdl.error = TypedPutHdlErrRef(
                pfx:  VtxPfx,
                vid:  vid,
                code: rc.error)
              return
            hdl.cache[VtxPfx][vid] = rc.value
          else:
            hdl.cache[VtxPfx][vid] = EmptyBlob

proc putKeyFn(db: RdbBackendRef): PutKeyFn =
  result =
    proc(hdl: PutHdlRef; vkps: openArray[(VertexID,HashKey)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        for (vid,key) in vkps:
          if key.isValid:
            hdl.cache[KeyPfx][vid] = key.to(Blob)
          else:
            hdl.cache[KeyPfx][vid] = EmptyBlob
            

proc putIdgFn(db: RdbBackendRef): PutIdgFn =
  result =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        if 0 < vs.len:
          hdl.cache[IdgPfx][VertexID(0)] = vs.blobify
        else:
          hdl.cache[IdgPfx][VertexID(0)] = EmptyBlob


proc putEndFn(db: RdbBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): AristoError =
      let hdl = hdl.endSession db
      if not hdl.error.isNil:
        case hdl.error.pfx:
        of VtxPfx, KeyPfx:
          debug logTxt "putEndFn: vtx/key failed",
            pfx=hdl.error.pfx, vid=hdl.error.vid, error=hdl.error.code
        else:
          debug logTxt "putEndFn: failed",
            pfx=hdl.error.pfx, error=hdl.error.code
        return hdl.error.code
      let rc = db.rdb.put hdl.cache
      if rc.isErr:
        when extraTraceMessages:
          debug logTxt "putEndFn: failed",
            error=rc.error[0], info=rc.error[1]
        return rc.error[0]
      AristoError(0)


proc closeFn(db: RdbBackendRef): CloseFn =
  result =
    proc(flush: bool) =
      db.rdb.destroy(flush)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rocksDbBackend*(path: string): Result[AristoBackendRef,AristoError] =
  let
    db = RdbBackendRef(kind: BackendRocksDB)
    rc = db.rdb.init(path, maxOpenFiles)
  if rc.isErr:
    when extraTraceMessages:
      trace logTxt "constructor failed",
        error=rc.error[0], info=rc.error[1]
    return err(rc.error[0])

  db.getVtxFn = getVtxFn db
  db.getKeyFn = getKeyFn db
  db.getIdgFn = getIdgFn db

  db.putBegFn = putBegFn db
  db.putVtxFn = putVtxFn db
  db.putKeyFn = putKeyFn db
  db.putIdgFn = putIdgFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

  ok db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walk*(
    be: RdbBackendRef;
      ): tuple[n: int, pfx: AristoStorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  for w in be.rdb.walk:
    yield w

iterator walkIdg*(
    be: RdbBackendRef;
      ): tuple[n: int, id: uint64, vGen: seq[VertexID]] =
  ## Variant of `walk()` iteration over the ID generator sub-table.
  for (n, id, data) in be.rdb.walk IdgPfx:
    let rc = data.deblobify seq[VertexID]
    if rc.isOk:
      yield (n, id, rc.value)

iterator walkVtx*(
    be: RdbBackendRef;
      ): tuple[n: int, vid: VertexID, vtx: VertexRef] =
  ## Variant of `walk()` iteration over the vertex sub-table.
  for (n, xid, data) in be.rdb.walk VtxPfx:
    let rc = data.deblobify VertexRef
    if rc.isOk:
      yield (n, VertexID(xid), rc.value)

iterator walkkey*(
    be: RdbBackendRef;
      ): tuple[n: int, vid: VertexID, key: HashKey] =
  ## Variant of `walk()` iteration over the Markle hash sub-table.
  for (n, xid, data) in be.rdb.walk KeyPfx:
    var hashKey: HashKey
    if hashKey.init data:
      yield (n, VertexID(xid), hashKey)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

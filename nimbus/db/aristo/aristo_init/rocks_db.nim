# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  results,
  ../aristo_constants,
  ../aristo_desc,
  ../aristo_desc/desc_backend,
  ../aristo_blobify,
  ./init_common,
  ./rocks_db/[rdb_desc, rdb_get, rdb_init, rdb_put, rdb_walk]

logScope:
  topics = "aristo-backend"

type
  RdbBackendRef* = ref object of TypedBackendRef
    rdb: RdbInst              ## Allows low level access to database
    noFq: bool                ## No filter queues available

  RdbPutHdlRef = ref object of TypedPutHdlRef
    cache: RdbTabs            ## Transaction cache

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


proc `vtxCache=`(hdl: RdbPutHdlRef; val: tuple[vid: VertexID; data: Blob]) =
  hdl.cache[VtxPfx][val.vid.uint64] = val.data

proc `keyCache=`(hdl: RdbPutHdlRef; val: tuple[vid: VertexID; data: Blob]) =
  hdl.cache[KeyPfx][val.vid.uint64] = val.data

proc `filCache=`(hdl: RdbPutHdlRef; val: tuple[qid: QueueID; data: Blob]) =
  hdl.cache[FilPfx][val.qid.uint64] = val.data

proc `admCache=`(hdl: RdbPutHdlRef; val: tuple[id: AdminTabID; data: Blob]) =
  hdl.cache[AdmPfx][val.id.uint64] = val.data

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
        let lid = HashKey.fromBytes(rc.value).valueOr:
          return err(RdbHashKeyExpected)
        return ok lid

      err(GetKeyNotFound)

proc getFilFn(db: RdbBackendRef): GetFilFn =
  if db.noFq:
    result =
      proc(qid: QueueID): Result[FilterRef,AristoError] =
        err(FilQuSchedDisabled)
  else:
    result =
      proc(qid: QueueID): Result[FilterRef,AristoError] =

        # Fetch serialised data record
        let rc = db.rdb.get qid.toOpenArray()
        if rc.isErr:
          debug logTxt "getFilFn: failed", qid,
            error=rc.error[0], info=rc.error[1]
          return err(rc.error[0])

        # Decode data record
        if 0 < rc.value.len:
          return rc.value.deblobify FilterRef

        err(GetFilNotFound)

proc getIdgFn(db: RdbBackendRef): GetIdgFn =
  result =
    proc(): Result[seq[VertexID],AristoError]=

      # Fetch serialised data record
      let rc = db.rdb.get AdmTabIdIdg.toOpenArray()
      if rc.isErr:
        debug logTxt "getIdgFn: failed", error=rc.error[1]
        return err(rc.error[0])

      if rc.value.len == 0:
        let w = EmptyVidSeq
        return ok w

      # Decode data record
      rc.value.deblobify seq[VertexID]

proc getFqsFn(db: RdbBackendRef): GetFqsFn =
  if db.noFq:
    result =
      proc(): Result[seq[(QueueID,QueueID)],AristoError] =
        err(FilQuSchedDisabled)
  else:
    result =
      proc(): Result[seq[(QueueID,QueueID)],AristoError]=

        # Fetch serialised data record
        let rc = db.rdb.get AdmTabIdFqs.toOpenArray()
        if rc.isErr:
          debug logTxt "getFqsFn: failed", error=rc.error[1]
          return err(rc.error[0])

        if rc.value.len == 0:
          let w = EmptyQidPairSeq
          return ok w

        # Decode data record
        rc.value.deblobify seq[(QueueID,QueueID)]

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
            let rc = vtx.blobify()
            if rc.isErr:
              hdl.error = TypedPutHdlErrRef(
                pfx:  VtxPfx,
                vid:  vid,
                code: rc.error)
              return
            hdl.vtxCache = (vid, rc.value)
          else:
            hdl.vtxCache = (vid, EmptyBlob)

proc putKeyFn(db: RdbBackendRef): PutKeyFn =
  result =
    proc(hdl: PutHdlRef; vkps: openArray[(VertexID,HashKey)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        for (vid,key) in vkps:
          if key.isValid:
            hdl.keyCache = (vid, @key)
          else:
            hdl.keyCache = (vid, EmptyBlob)

proc putFilFn(db: RdbBackendRef): PutFilFn =
  if db.noFq:
    result =
      proc(hdl: PutHdlRef; vf: openArray[(QueueID,FilterRef)]) =
        let hdl = hdl.getSession db
        if hdl.error.isNil:
          hdl.error = TypedPutHdlErrRef(
            pfx:  FilPfx,
            qid:  (if 0 < vf.len: vf[0][0] else: QueueID(0)),
            code: FilQuSchedDisabled)
  else:
    result =
      proc(hdl: PutHdlRef; vrps: openArray[(QueueID,FilterRef)]) =
        let hdl = hdl.getSession db
        if hdl.error.isNil:
          for (qid,filter) in vrps:
            if filter.isValid:
              let rc = filter.blobify()
              if rc.isErr:
                hdl.error = TypedPutHdlErrRef(
                  pfx:  FilPfx,
                  qid:  qid,
                  code: rc.error)
                return
              hdl.filCache = (qid, rc.value)
            else:
              hdl.filCache = (qid, EmptyBlob)

proc putIdgFn(db: RdbBackendRef): PutIdgFn =
  result =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        if 0 < vs.len:
          hdl.admCache = (AdmTabIdIdg, vs.blobify)
        else:
          hdl.admCache = (AdmTabIdIdg, EmptyBlob)

proc putFqsFn(db: RdbBackendRef): PutFqsFn =
  if db.noFq:
    result =
      proc(hdl: PutHdlRef; fs: openArray[(QueueID,QueueID)])  =
        let hdl = hdl.getSession db
        if hdl.error.isNil:
          hdl.error = TypedPutHdlErrRef(
            pfx:  AdmPfx,
            code: FilQuSchedDisabled)
  else:
    result =
      proc(hdl: PutHdlRef; vs: openArray[(QueueID,QueueID)])  =
        let hdl = hdl.getSession db
        if hdl.error.isNil:
          if 0 < vs.len:
            hdl.admCache = (AdmTabIdFqs, vs.blobify)
          else:
            hdl.admCache = (AdmTabIdFqs, EmptyBlob)


proc putEndFn(db: RdbBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,AristoError] =
      let hdl = hdl.endSession db
      if not hdl.error.isNil:
        case hdl.error.pfx:
        of VtxPfx, KeyPfx:
          debug logTxt "putEndFn: vtx/key failed",
            pfx=hdl.error.pfx, vid=hdl.error.vid, error=hdl.error.code
        else:
          debug logTxt "putEndFn: failed",
            pfx=hdl.error.pfx, error=hdl.error.code
        return err(hdl.error.code)
      let rc = db.rdb.put hdl.cache
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
    qidLayout: QidLayoutRef;
      ): Result[BackendRef,AristoError] =
  let db = RdbBackendRef(
    beKind: BackendRocksDB,
    noFq:   qidLayout.isNil)

  # Initialise RocksDB
  block:
    let rc = db.rdb.init(path, maxOpenFiles)
    if rc.isErr:
      when extraTraceMessages:
        trace logTxt "constructor failed",
           error=rc.error[0], info=rc.error[1]
        return err(rc.error[0])

  db.getVtxFn = getVtxFn db
  db.getKeyFn = getKeyFn db
  db.getFilFn = getFilFn db
  db.getIdgFn = getIdgFn db
  db.getFqsFn = getFqsFn db

  db.putBegFn = putBegFn db
  db.putVtxFn = putVtxFn db
  db.putKeyFn = putKeyFn db
  db.putFilFn = putFilFn db
  db.putIdgFn = putIdgFn db
  db.putFqsFn = putFqsFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

  # Set up filter management table
  if not db.noFq:
    db.filters = QidSchedRef(ctx: qidLayout)
    db.filters.state = block:
      let rc = db.getFqsFn()
      if rc.isErr:
        db.closeFn(flush = false)
        return err(rc.error)
      rc.value

  ok db

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
  if be.noFq:
    for w in be.rdb.walk:
      case w.pfx:
      of AdmPfx:
        if w.xid == AdmTabIdFqs.uint64:
          continue
      of FilPfx:
        break # last sub-table
      else:
        discard
      yield w
  else:
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

iterator walkFil*(
    be: RdbBackendRef;
      ): tuple[qid: QueueID, filter: FilterRef] =
  ## Variant of `walk()` iteration over the filter sub-table.
  if not be.noFq:
    for (xid, data) in be.rdb.walk FilPfx:
      let rc = data.deblobify FilterRef
      if rc.isOk:
        yield (QueueID(xid), rc.value)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

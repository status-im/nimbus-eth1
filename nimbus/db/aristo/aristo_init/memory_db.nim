# nimbus-eth1
# Copyright (c) 2023=-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## In-memory backend for Aristo DB
## ===============================
##
## The iterators provided here are currently available only by direct
## backend access
## ::
##   import
##     aristo/aristo_init,
##     aristo/aristo_init/aristo_memory
##
##   let rc = newAristoDbRef(BackendMemory)
##   if rc.isOk:
##     let be = rc.value.to(MemBackendRef)
##     for (n, key, vtx) in be.walkVtx:
##       ...
##
{.push raises: [].}

import
  std/[algorithm, options, sequtils, tables],
  eth/common,
  results,
  ../aristo_constants,
  ../aristo_desc,
  ../aristo_desc/desc_backend,
  ../aristo_blobify,
  ./init_common

const
   extraTraceMessages = false or true
     ## Enabled additional logging noise

type
  MemDbRef = ref object
    ## Database
    sTab: Table[VertexID,Blob]       ## Structural vertex table making up a trie
    kMap: Table[VertexID,HashKey]    ## Merkle hash key mapping
    rFil: Table[QueueID,Blob]        ## Backend journal filters
    vGen: Option[seq[VertexID]]      ## ID generator state
    lSst: Option[SavedState]         ## Last saved state
    vFqs: Option[seq[(QueueID,QueueID)]]
    noFq: bool                       ## No filter queues available

  MemBackendRef* = ref object of TypedBackendRef
    ## Inheriting table so access can be extended for debugging purposes
    mdb: MemDbRef                    ## Database

  MemPutHdlRef = ref object of TypedPutHdlRef
    sTab: Table[VertexID,Blob]
    kMap: Table[VertexID,HashKey]
    rFil: Table[QueueID,Blob]
    vGen: Option[seq[VertexID]]
    lSst: Option[SavedState]
    vFqs: Option[seq[(QueueID,QueueID)]]

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-backend"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "MemoryDB/" & info

proc newSession(db: MemBackendRef): MemPutHdlRef =
  new result
  result.TypedPutHdlRef.beginSession db

proc getSession(hdl: PutHdlRef; db: MemBackendRef): MemPutHdlRef =
  hdl.TypedPutHdlRef.verifySession db
  hdl.MemPutHdlRef

proc endSession(hdl: PutHdlRef; db: MemBackendRef): MemPutHdlRef =
  hdl.TypedPutHdlRef.finishSession db
  hdl.MemPutHdlRef

# ------------------------------------------------------------------------------
# Private functions: interface
# ------------------------------------------------------------------------------

proc getVtxFn(db: MemBackendRef): GetVtxFn =
  result =
    proc(vid: VertexID): Result[VertexRef,AristoError] =
      # Fetch serialised data record
      let data = db.mdb.sTab.getOrDefault(vid, EmptyBlob)
      if 0 < data.len:
        let rc = data.deblobify(VertexRef)
        when extraTraceMessages:
          if rc.isErr:
            trace logTxt "getVtxFn() failed", vid, error=rc.error
        return rc
      err(GetVtxNotFound)

proc getKeyFn(db: MemBackendRef): GetKeyFn =
  result =
    proc(vid: VertexID): Result[HashKey,AristoError] =
      let key = db.mdb.kMap.getOrVoid vid
      if key.isValid:
        return ok key
      err(GetKeyNotFound)

proc getFilFn(db: MemBackendRef): GetFilFn =
  if db.mdb.noFq:
    result =
      proc(qid: QueueID): Result[FilterRef,AristoError] =
        err(FilQuSchedDisabled)
  else:
    result =
      proc(qid: QueueID): Result[FilterRef,AristoError] =
        let data = db.mdb.rFil.getOrDefault(qid, EmptyBlob)
        if 0 < data.len:
          return data.deblobify FilterRef
        err(GetFilNotFound)

proc getIdgFn(db: MemBackendRef): GetIdgFn =
  result =
    proc(): Result[seq[VertexID],AristoError]=
      if db.mdb.vGen.isSome:
        return ok db.mdb.vGen.unsafeGet
      err(GetIdgNotFound)

proc getLstFn(db: MemBackendRef): GetLstFn =
  result =
    proc(): Result[SavedState,AristoError]=
      if db.mdb.lSst.isSome:
        return ok db.mdb.lSst.unsafeGet
      err(GetLstNotFound)

proc getFqsFn(db: MemBackendRef): GetFqsFn =
  if db.mdb.noFq:
    result =
      proc(): Result[seq[(QueueID,QueueID)],AristoError] =
        err(FilQuSchedDisabled)
  else:
    result =
      proc(): Result[seq[(QueueID,QueueID)],AristoError] =
        if db.mdb.vFqs.isSome:
          return ok db.mdb.vFqs.unsafeGet
        err(GetFqsNotFound)

# -------------

proc putBegFn(db: MemBackendRef): PutBegFn =
  result =
    proc(): PutHdlRef =
      db.newSession()


proc putVtxFn(db: MemBackendRef): PutVtxFn =
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
            hdl.sTab[vid] = rc.value
          else:
            hdl.sTab[vid] = EmptyBlob

proc putKeyFn(db: MemBackendRef): PutKeyFn =
  result =
    proc(hdl: PutHdlRef; vkps: openArray[(VertexID,HashKey)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        for (vid,key) in vkps:
          hdl.kMap[vid] = key

proc putFilFn(db: MemBackendRef): PutFilFn =
  if db.mdb.noFq:
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
      proc(hdl: PutHdlRef; vf: openArray[(QueueID,FilterRef)]) =
        let hdl = hdl.getSession db
        if hdl.error.isNil:
          for (qid,filter) in vf:
            if filter.isValid:
              let rc = filter.blobify()
              if rc.isErr:
                hdl.error = TypedPutHdlErrRef(
                  pfx:  FilPfx,
                  qid:  qid,
                  code: rc.error)
                return
              hdl.rFil[qid] = rc.value
            else:
              hdl.rFil[qid] = EmptyBlob

proc putIdgFn(db: MemBackendRef): PutIdgFn =
  result =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        hdl.vGen = some(vs.toSeq)

proc putLstFn(db: MemBackendRef): PutLstFn =
  result =
    proc(hdl: PutHdlRef; lst: SavedState) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        hdl.lSst = some(lst)

proc putFqsFn(db: MemBackendRef): PutFqsFn =
  if db.mdb.noFq:
    result =
      proc(hdl: PutHdlRef; fs: openArray[(QueueID,QueueID)])  =
        let hdl = hdl.getSession db
        if hdl.error.isNil:
          hdl.error = TypedPutHdlErrRef(
            pfx:  AdmPfx,
            aid:  AdmTabIdFqs,
            code: FilQuSchedDisabled)
  else:
    result =
      proc(hdl: PutHdlRef; fs: openArray[(QueueID,QueueID)])  =
        let hdl = hdl.getSession db
        if hdl.error.isNil:
          hdl.vFqs = some(fs.toSeq)


proc putEndFn(db: MemBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,AristoError] =
      let hdl = hdl.endSession db
      if not hdl.error.isNil:
        when extraTraceMessages:
          case hdl.error.pfx:
          of VtxPfx, KeyPfx: trace logTxt "putEndFn: vtx/key failed",
            pfx=hdl.error.pfx, vid=hdl.error.vid, error=hdl.error.code
          of FilPfx: trace logTxt "putEndFn: filter failed",
            pfx=hdl.error.pfx, qid=hdl.error.qid, error=hdl.error.code
          of AdmPfx: trace logTxt "putEndFn: admin failed",
            pfx=AdmPfx, aid=hdl.error.aid.uint64, error=hdl.error.code
          of Oops: trace logTxt "putEndFn: failed",
             pfx=hdl.error.pfx, error=hdl.error.code
        return err(hdl.error.code)

      for (vid,data) in hdl.sTab.pairs:
        if 0 < data.len:
          db.mdb.sTab[vid] = data
        else:
          db.mdb.sTab.del vid

      for (vid,key) in hdl.kMap.pairs:
        if key.isValid:
          db.mdb.kMap[vid] = key
        else:
          db.mdb.kMap.del vid

      for (qid,data) in hdl.rFil.pairs:
        if 0 < data.len:
          db.mdb.rFil[qid] = data
        else:
          db.mdb.rFil.del qid

      if hdl.vGen.isSome:
        let vGen = hdl.vGen.unsafeGet
        if vGen.len == 0:
          db.mdb.vGen = none(seq[VertexID])
        else:
          db.mdb.vGen = some(vGen)

      if hdl.lSst.isSome:
        db.mdb.lSst = hdl.lSst

      if hdl.vFqs.isSome:
        let vFqs = hdl.vFqs.unsafeGet
        if vFqs.len == 0:
          db.mdb.vFqs = none(seq[(QueueID,QueueID)])
        else:
          db.mdb.vFqs = some(vFqs)

      ok()

# -------------

proc guestDbFn(db: MemBackendRef): GuestDbFn =
  result =
    proc(instance: int): Result[RootRef,AristoError] =
      ok(RootRef nil)

proc closeFn(db: MemBackendRef): CloseFn =
  result =
    proc(ignore: bool) =
      discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*(qidLayout: QidLayoutRef): BackendRef =
  let db = MemBackendRef(
    beKind: BackendMemory,
    mdb:    MemDbRef())

  db.mdb.noFq = qidLayout.isNil

  db.getVtxFn = getVtxFn db
  db.getKeyFn = getKeyFn db
  db.getFilFn = getFilFn db
  db.getIdgFn = getIdgFn db
  db.getLstFn = getLstFn db
  db.getFqsFn = getFqsFn db

  db.putBegFn = putBegFn db
  db.putVtxFn = putVtxFn db
  db.putKeyFn = putKeyFn db
  db.putFilFn = putFilFn db
  db.putIdgFn = putIdgFn db
  db.putLstFn = putLstFn db
  db.putFqsFn = putFqsFn db
  db.putEndFn = putEndFn db

  db.guestDbFn = guestDbFn db

  db.closeFn = closeFn db

  # Set up filter management table
  if not db.mdb.noFq:
    db.journal = QidSchedRef(ctx: qidLayout)

  db

proc dup*(db: MemBackendRef): MemBackendRef =
  ## Duplicate descriptor shell as needed for API debugging
  new result
  init_common.init(result[], db[])
  result.mdb = db.mdb

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walkVtx*(
    be: MemBackendRef;
      ): tuple[vid: VertexID, vtx: VertexRef] =
  ##  Iteration over the vertex sub-table.
  for n,vid in be.mdb.sTab.keys.toSeq.mapIt(it).sorted:
    let data = be.mdb.sTab.getOrDefault(vid, EmptyBlob)
    if 0 < data.len:
      let rc = data.deblobify VertexRef
      if rc.isErr:
        when extraTraceMessages:
          debug logTxt "walkVtxFn() skip", n, vid, error=rc.error
      else:
        yield (vid, rc.value)

iterator walkKey*(
    be: MemBackendRef;
      ): tuple[vid: VertexID, key: HashKey] =
  ## Iteration over the Markle hash sub-table.
  for vid in be.mdb.kMap.keys.toSeq.mapIt(it).sorted:
    let key = be.mdb.kMap.getOrVoid vid
    if key.isValid:
      yield (vid, key)

iterator walkFil*(
    be: MemBackendRef;
      ): tuple[qid: QueueID, filter: FilterRef] =
  ##  Iteration over the vertex sub-table.
  if not be.mdb.noFq:
    for n,qid in be.mdb.rFil.keys.toSeq.mapIt(it).sorted:
      let data = be.mdb.rFil.getOrDefault(qid, EmptyBlob)
      if 0 < data.len:
        let rc = data.deblobify FilterRef
        if rc.isErr:
          when extraTraceMessages:
            debug logTxt "walkFilFn() skip", n, qid, error=rc.error
        else:
          yield (qid, rc.value)


iterator walk*(
    be: MemBackendRef;
      ): tuple[pfx: StorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  if be.mdb.vGen.isSome:
    yield(AdmPfx, AdmTabIdIdg.uint64, be.mdb.vGen.unsafeGet.blobify)

  if not be.mdb.noFq:
    if be.mdb.vFqs.isSome:
      yield(AdmPfx, AdmTabIdFqs.uint64, be.mdb.vFqs.unsafeGet.blobify)

  for vid in be.mdb.sTab.keys.toSeq.mapIt(it).sorted:
    let data = be.mdb.sTab.getOrDefault(vid, EmptyBlob)
    if 0 < data.len:
      yield (VtxPfx, vid.uint64, data)

  for (vid,key) in be.walkKey:
    yield (KeyPfx, vid.uint64, @(key.data))

  if not be.mdb.noFq:
    for lid in be.mdb.rFil.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.QueueID):
      let data = be.mdb.rFil.getOrDefault(lid, EmptyBlob)
      if 0 < data.len:
        yield (FilPfx, lid.uint64, data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

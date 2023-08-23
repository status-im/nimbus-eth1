# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  chronicles,
  eth/common,
  stew/results,
  ../aristo_constants,
  ../aristo_desc,
  ../aristo_desc/aristo_types_backend,
  ../aristo_transcode,
  ./aristo_init_common

type
  MemBackendRef* = ref object of TypedBackendRef
    ## Inheriting table so access can be extended for debugging purposes
    sTab: Table[VertexID,Blob]       ## Structural vertex table making up a trie
    kMap: Table[VertexID,HashKey]    ## Merkle hash key mapping
    rFil: Table[QueueID,Blob]       ## Backend filters
    vGen: Option[seq[VertexID]]
    vFqs: Option[seq[(QueueID,QueueID)]]

  MemPutHdlRef = ref object of TypedPutHdlRef
    sTab: Table[VertexID,Blob]
    kMap: Table[VertexID,HashKey]
    rFil: Table[QueueID,Blob]
    vGen: Option[seq[VertexID]]
    vFqs: Option[seq[(QueueID,QueueID)]]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "MemoryDB " & info


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
      let data = db.sTab.getOrDefault(vid, EmptyBlob)
      if 0 < data.len:
        let rc = data.deblobify VertexRef
        if rc.isErr:
          debug logTxt "getVtxFn() failed", vid, error=rc.error, info=rc.error
        return rc
      err(GetVtxNotFound)

proc getKeyFn(db: MemBackendRef): GetKeyFn =
  result =
    proc(vid: VertexID): Result[HashKey,AristoError] =
      let key = db.kMap.getOrDefault(vid, VOID_HASH_KEY)
      if key.isValid:
        return ok key
      err(GetKeyNotFound)

proc getFilFn(db: MemBackendRef): GetFilFn =
  result =
    proc(qid: QueueID): Result[FilterRef,AristoError] =
      let data = db.rFil.getOrDefault(qid, EmptyBlob)
      if 0 < data.len:
        return data.deblobify FilterRef
      err(GetFilNotFound)

proc getIdgFn(db: MemBackendRef): GetIdgFn =
  result =
    proc(): Result[seq[VertexID],AristoError]=
      if db.vGen.isSome:
        return ok db.vGen.unsafeGet
      err(GetIdgNotFound)

proc getFqsFn(db: MemBackendRef): GetFqsFn =
  result =
    proc(): Result[seq[(QueueID,QueueID)],AristoError]=
      if db.vFqs.isSome:
        return ok db.vFqs.unsafeGet
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
  result =
    proc(hdl: PutHdlRef; vf: openArray[(QueueID,FilterRef)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        for (qid,filter) in vf:
          let rc = filter.blobify()
          if rc.isErr:
            hdl.error = TypedPutHdlErrRef(
              pfx:  FilPfx,
              qid:  qid,
              code: rc.error)
            return
          hdl.rFil[qid] = rc.value

proc putIdgFn(db: MemBackendRef): PutIdgFn =
  result =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        hdl.vGen = some(vs.toSeq)

proc putFqsFn(db: MemBackendRef): PutFqsFn =
  result =
    proc(hdl: PutHdlRef; fs: openArray[(QueueID,QueueID)])  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        hdl.vFqs = some(fs.toSeq)


proc putEndFn(db: MemBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): AristoError =
      let hdl = hdl.endSession db
      if not hdl.error.isNil:
        case hdl.error.pfx:
        of VtxPfx, KeyPfx:
          debug logTxt "putEndFn: vtx/key failed",
            pfx=hdl.error.pfx, vid=hdl.error.vid, error=hdl.error.code
        of FilPfx:
          debug logTxt "putEndFn: filter failed",
            pfx=hdl.error.pfx, qid=hdl.error.qid, error=hdl.error.code
        else:
          debug logTxt "putEndFn: failed",
            pfx=hdl.error.pfx, error=hdl.error.code
        return hdl.error.code

      for (vid,data) in hdl.sTab.pairs:
        if 0 < data.len:
          db.sTab[vid] = data
        else:
          db.sTab.del vid

      for (vid,key) in hdl.kMap.pairs:
        if key.isValid:
          db.kMap[vid] = key
        else:
          db.kMap.del vid

      for (qid,data) in hdl.rFil.pairs:
        if qid.isValid:
          db.rFil[qid] = data
        else:
          db.rFil.del qid

      if hdl.vGen.isSome:
        let vGen = hdl.vGen.unsafeGet
        if vGen.len == 0:
          db.vGen = none(seq[VertexID])
        else:
          db.vGen = some(vGen)

      if hdl.vFqs.isSome:
        let vFqs = hdl.vFqs.unsafeGet
        if vFqs.len == 0:
          db.vFqs = none(seq[(QueueID,QueueID)])
        else:
          db.vFqs = some(vFqs)

      AristoError(0)

# -------------

proc closeFn(db: MemBackendRef): CloseFn =
  result =
    proc(ignore: bool) =
      discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*(): BackendRef =
  let db = MemBackendRef(kind: BackendMemory)

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

  db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walkVtx*(
    be: MemBackendRef;
      ): tuple[n: int, vid: VertexID, vtx: VertexRef] =
  ##  Iteration over the vertex sub-table.
  for n,vid in be.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let data = be.sTab.getOrDefault(vid, EmptyBlob)
    if 0 < data.len:
      let rc = data.deblobify VertexRef
      if rc.isErr:
        debug logTxt "walkVtxFn() skip", n, vid, error=rc.error
      else:
        yield (n, vid, rc.value)

iterator walkKey*(
    be: MemBackendRef;
      ): tuple[n: int, vid: VertexID, key: HashKey] =
  ## Iteration over the Markle hash sub-table.
  for n,vid in be.kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = be.kMap.getOrDefault(vid, VOID_HASH_KEY)
    if key.isValid:
      yield (n, vid, key)

iterator walkFil*(
    be: MemBackendRef;
      ): tuple[n: int, qid: QueueID, filter: FilterRef] =
  ##  Iteration over the vertex sub-table.
  for n,qid in be.rFil.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.QueueID):
    let data = be.rFil.getOrDefault(qid, EmptyBlob)
    if 0 < data.len:
      let rc = data.deblobify FilterRef
      if rc.isErr:
        debug logTxt "walkFilFn() skip", n,qid, error=rc.error
      else:
        yield (n, qid, rc.value)


iterator walk*(
    be: MemBackendRef;
      ): tuple[n: int, pfx: StorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  var n = 0

  if be.vGen.isSome:
    yield(0, AdmPfx, AdmTabIdIdg.uint64, be.vGen.unsafeGet.blobify)
    n.inc

  if be.vFqs.isSome:
    yield(0, AdmPfx, AdmTabIdFqs.uint64, be.vFqs.unsafeGet.blobify)
    n.inc

  for vid in be.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let data = be.sTab.getOrDefault(vid, EmptyBlob)
    if 0 < data.len:
      yield (n, VtxPfx, vid.uint64, data)
    n.inc

  for (_,vid,key) in be.walkKey:
    yield (n, KeyPfx, vid.uint64, key.to(Blob))
    n.inc

  for lid in be.rFil.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.QueueID):
    let data = be.rFil.getOrDefault(lid, EmptyBlob)
    if 0 < data.len:
      yield (n, FilPfx, lid.uint64, data)
    n.inc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

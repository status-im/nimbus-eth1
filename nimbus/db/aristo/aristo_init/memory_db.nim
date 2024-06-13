# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
    tUvi: Option[VertexID]           ## Top used vertex ID
    lSst: Opt[SavedState]            ## Last saved state

  MemBackendRef* = ref object of TypedBackendRef
    ## Inheriting table so access can be extended for debugging purposes
    mdb: MemDbRef                    ## Database

  MemPutHdlRef = ref object of TypedPutHdlRef
    sTab: Table[VertexID,Blob]
    kMap: Table[VertexID,HashKey]
    tUvi: Option[VertexID]
    lSst: Opt[SavedState]

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

proc getTuvFn(db: MemBackendRef): GetTuvFn =
  result =
    proc(): Result[VertexID,AristoError]=
      if db.mdb.tUvi.isSome:
        return ok db.mdb.tUvi.unsafeGet
      err(GetTuvNotFound)

proc getLstFn(db: MemBackendRef): GetLstFn =
  result =
    proc(): Result[SavedState,AristoError]=
      if db.mdb.lSst.isSome:
        return ok db.mdb.lSst.unsafeGet
      err(GetLstNotFound)

# -------------

proc putBegFn(db: MemBackendRef): PutBegFn =
  result =
    proc(): Result[PutHdlRef,AristoError] =
      ok db.newSession()


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

proc putTuvFn(db: MemBackendRef): PutTuvFn =
  result =
    proc(hdl: PutHdlRef; vs: VertexID)  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        hdl.tUvi = some(vs)

proc putLstFn(db: MemBackendRef): PutLstFn =
  result =
    proc(hdl: PutHdlRef; lst: SavedState) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        let rc = lst.blobify # test
        if rc.isOk:
          hdl.lSst = Opt.some(lst)
        else:
          hdl.error = TypedPutHdlErrRef(
            pfx:  AdmPfx,
            aid:  AdmTabIdLst,
            code: rc.error)

proc putEndFn(db: MemBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): Result[void,AristoError] =
      let hdl = hdl.endSession db
      if not hdl.error.isNil:
        when extraTraceMessages:
          case hdl.error.pfx:
          of VtxPfx, KeyPfx: trace logTxt "putEndFn: vtx/key failed",
            pfx=hdl.error.pfx, vid=hdl.error.vid, error=hdl.error.code
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

      let tuv = hdl.tUvi.get(otherwise = VertexID(0))
      if tuv.isValid:
        db.mdb.tUvi = some(tuv)

      if hdl.lSst.isSome:
        db.mdb.lSst = hdl.lSst

      ok()

# -------------

proc closeFn(db: MemBackendRef): CloseFn =
  result =
    proc(ignore: bool) =
      discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*(): BackendRef =
  let db = MemBackendRef(
    beKind: BackendMemory,
    mdb:    MemDbRef())

  db.getVtxFn = getVtxFn db
  db.getKeyFn = getKeyFn db
  db.getTuvFn = getTuvFn db
  db.getLstFn = getLstFn db

  db.putBegFn = putBegFn db
  db.putVtxFn = putVtxFn db
  db.putKeyFn = putKeyFn db
  db.putTuvFn = putTuvFn db
  db.putLstFn = putLstFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db
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


iterator walk*(
    be: MemBackendRef;
      ): tuple[pfx: StorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  if be.mdb.tUvi.isSome:
    yield(AdmPfx, AdmTabIdTuv.uint64, be.mdb.tUvi.unsafeGet.blobify)
  if be.mdb.lSst.isSome:
    yield(AdmPfx, AdmTabIdLst.uint64, be.mdb.lSst.unsafeGet.blobify.value)

  for vid in be.mdb.sTab.keys.toSeq.mapIt(it).sorted:
    let data = be.mdb.sTab.getOrDefault(vid, EmptyBlob)
    if 0 < data.len:
      yield (VtxPfx, vid.uint64, data)

  for (vid,key) in be.walkKey:
    yield (KeyPfx, vid.uint64, @(key.data))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

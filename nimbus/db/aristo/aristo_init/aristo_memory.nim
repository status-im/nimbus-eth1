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
  std/[algorithm, sequtils, tables],
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
    sTab: Table[VertexID,VertexRef]  ## Structural vertex table making up a trie
    kMap: Table[VertexID,HashKey]    ## Merkle hash key mapping
    vGen: seq[VertexID]

  MemPutHdlRef = ref object of TypedPutHdlRef
    sTab: Table[VertexID,VertexRef]
    kMap: Table[VertexID,HashKey]
    vGen: seq[VertexID]
    vGenOk: bool

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
      let vtx = db.sTab.getOrVoid vid
      if vtx.isValid:
        return ok vtx.dup
      err(GetVtxNotFound)

proc getKeyFn(db: MemBackendRef): GetKeyFn =
  result =
    proc(vid: VertexID): Result[HashKey,AristoError] =
      let key = db.kMap.getOrDefault(vid, VOID_HASH_KEY)
      if key.isValid:
        return ok key
      err(GetKeyNotFound)

proc getIdgFn(db: MemBackendRef): GetIdgFn =
  result =
    proc(): Result[seq[VertexID],AristoError]=
      ok db.vGen

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
          if not vtx.isNil:
            let rc = vtx.blobify # verify data record
            if rc.isErr:
              hdl.error = TypedPutHdlErrRef(
                pfx:  VtxPfx,
                vid:  vid,
                code: rc.error)
              return
          hdl.sTab[vid] = vtx.dup

proc putKeyFn(db: MemBackendRef): PutKeyFn =
  result =
    proc(hdl: PutHdlRef; vkps: openArray[(VertexID,HashKey)]) =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        for (vid,key) in vkps:
          hdl.kMap[vid] = key

proc putIdgFn(db: MemBackendRef): PutIdgFn =
  result =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])  =
      let hdl = hdl.getSession db
      if hdl.error.isNil:
        hdl.vGen = vs.toSeq
        hdl.vGenOk = true


proc putEndFn(db: MemBackendRef): PutEndFn =
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

      for (vid,vtx) in hdl.sTab.pairs:
        if vtx.isValid:
          db.sTab[vid] = vtx
        else:
          db.sTab.del vid

      for (vid,key) in hdl.kMap.pairs:
        if key.isValid:
          db.kMap[vid] = key
        else:
          db.kMap.del vid

      if hdl.vGenOk:
        db.vGen = hdl.vGen
      AristoError(0)

# -------------

proc closeFn(db: MemBackendRef): CloseFn =
  result =
    proc(ignore: bool) =
      discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*(): AristoBackendRef =
  let db = MemBackendRef(kind: BackendMemory)

  db.getVtxFn = getVtxFn db
  db.getKeyFn = getKeyFn db
  db.getIdgFn = getIdgFn db

  db.putBegFn = putBegFn db
  db.putVtxFn = putVtxFn db
  db.putKeyFn = putKeyFn db
  db.putIdgFn = putIdgFn db
  db.putEndFn = putEndFn db

  db.closeFn = closeFn db

  db

# ------------------------------------------------------------------------------
# Public iterators (needs direct backend access)
# ------------------------------------------------------------------------------

iterator walkIdg*(
    be: MemBackendRef;
      ): tuple[n: int, id: uint64, vGen: seq[VertexID]] =
  ## Iteration over the ID generator sub-table (there is at most one instance).
  if 0 < be.vGen.len:
    yield(0, 0u64, be.vGen)

iterator walkVtx*(
    be: MemBackendRef;
      ): tuple[n: int, vid: VertexID, vtx: VertexRef] =
  ##  Iteration over the vertex sub-table.
  for n,vid in be.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let vtx = be.sTab.getOrVoid vid
    if vtx.isValid:
      yield (n, vid, vtx)

iterator walkKey*(
    be: MemBackendRef;
      ): tuple[n: int, vid: VertexID, key: HashKey] =
  ## Iteration over the Markle hash sub-table.
  for n,vid in be.kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = be.kMap.getOrDefault(vid, VOID_HASH_KEY)
    if key.isValid:
      yield (n, vid, key)

iterator walk*(
    be: MemBackendRef;
      ): tuple[n: int, pfx: AristoStorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  var n = 0
  for (_,id,vGen) in be.walkIdg:
    yield (n, IdgPfx, id, vGen.blobify)
    n.inc

  for (_,vid,vtx) in be.walkVtx:
    let rc = vtx.blobify
    if rc.isOk:
      yield (n, VtxPfx, vid.uint64, rc.value)
    n.inc

  for (_,vid,key) in be.walkKey:
    yield (n, KeyPfx, vid.uint64, key.to(Blob))
    n.inc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

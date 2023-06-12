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

{.push raises: [].}

import
  std/[sequtils, tables],
  stew/results,
  ../aristo_desc,
  ../aristo_desc/aristo_types_backend

type
  MemBackendRef = ref object
    sTab: Table[VertexID,VertexRef]  ## Structural vertex table making up a trie
    kMap: Table[VertexID,NodeKey]    ## Merkle hash key mapping
    vGen: seq[VertexID]
    txGen: uint                      ## Transaction ID generator (for debugging)
    txId: uint                       ## Active transaction ID (for debugging)

  MemPutHdlRef = ref object of PutHdlRef
    txId: uint                       ## Transaction ID (for debugging)

const
  VerifyIxId = true # for debugging

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getVtxFn(db: MemBackendRef): GetVtxFn =
  result =
    proc(vid: VertexID): Result[VertexRef,AristoError] =
      let vtx = db.sTab.getOrDefault(vid, VertexRef(nil))
      if vtx != VertexRef(nil):
        return ok vtx
      err(MemBeVtxNotFound)

proc getKeyFn(db: MemBackendRef): GetKeyFn =
  result =
    proc(vid: VertexID): Result[NodeKey,AristoError] =
      let key = db.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
      if key != EMPTY_ROOT_KEY:
        return ok key
      err(MemBeKeyNotFound)

proc getIdgFn(db: MemBackendRef): GetIdgFn =
  result =
    proc(): Result[seq[VertexID],AristoError]=
      ok db.vGen

# -------------

proc putBegFn(db: MemBackendRef): PutBegFn =
  result =
    proc(): PutHdlRef =
      when VerifyIxId:
        doAssert db.txId == 0
        db.txGen.inc
      MemPutHdlRef(txId: db.txGen)


proc putVtxFn(db: MemBackendRef): PutVtxFn =
  result =
    proc(hdl: PutHdlRef; vrps: openArray[(VertexID,VertexRef)]) =
      when VerifyIxId:
        doAssert db.txId == hdl.MemPutHdlRef.txId
      for (vid,vtx) in vrps:
        db.sTab[vid] = vtx

proc putKeyFn(db: MemBackendRef): PutKeyFn =
  result =
    proc(hdl: PutHdlRef; vkps: openArray[(VertexID,NodeKey)]) =
      when VerifyIxId:
        doAssert db.txId == hdl.MemPutHdlRef.txId
      for (vid,key) in vkps:
        db.kMap[vid] = key

proc putIdgFn(db: MemBackendRef): PutIdgFn =
  result =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])  =
      when VerifyIxId:
        doAssert db.txId == hdl.MemPutHdlRef.txId
      db.vGen = vs.toSeq


proc putEndFn(db: MemBackendRef): PutEndFn =
  result =
    proc(hdl: PutHdlRef): AristoError =
      when VerifyIxId:
        doAssert db.txId == hdl.MemPutHdlRef.txId
        db.txId = 0
      AristoError(0)

# -------------

proc delVtxFn(db: MemBackendRef): DelVtxFn =
  result =
    proc(vids: openArray[VertexID]) =
      for vid in vids:
        db.sTab.del vid

proc delKeyFn(db: MemBackendRef): DelKeyFn =
  result =
    proc(vids: openArray[VertexID]) =
      for vid in vids:
        db.kMap.del vid

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*(): AristoBackendRef =
  let db = MemBackendRef()

  AristoBackendRef(
    getVtxFn: getVtxFn db,
    getKeyFn: getKeyFn db,
    getIdgFn: getIdgFn db,

    putBegFn: putBegFn db,
    putVtxFn: putVtxFn db,
    putKeyFn: putKeyFn db,
    putIdgFn: putIdgFn db,
    putEndFn: putEndFn db,

    delVtxFn: delVtxFn db,
    delKeyFn: delKeyFn db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

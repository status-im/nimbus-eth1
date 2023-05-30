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
  std/tables,
  stew/results,
  ../../../sync/snap/range_desc,
  ".."/[aristo_constants, aristo_desc, aristo_error]

type
  MemBackendRef = ref object
    sTab: Table[VertexID,VertexRef]  ## Structural vertex table making up a trie
    kMap: Table[VertexID,NodeKey]    ## Merkle hash key mapping

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

proc putVtxFn(db: MemBackendRef): PutVtxFn =
  result =
    proc(vrps: openArray[(VertexID,VertexRef)]): AristoError =
      for (vid,vtx) in vrps:
        db.sTab[vid] = vtx

proc putKeyFn(db: MemBackendRef): PutKeyFn =
  result =
    proc(vkps: openArray[(VertexID,NodeKey)]): AristoError =
      for (vid,key) in vkps:
        db.kMap[vid] = key

proc delFn(db: MemBackendRef): DelFn =
  result =
    proc(vids: openArray[VertexID]) =
      for vid in vids:
        db.sTab.del vid
        db.kMap.del vid

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc memoryBackend*(): AristoBackendRef =
  let db = MemBackendRef()

  AristoBackendRef(
    getVtxFn: getVtxFn db,
    getKeyFn: getKeyFn db,
    putVtxFn: putVtxFn db,
    putKeyFn: putKeyFn db,
    delFn:    delFn db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

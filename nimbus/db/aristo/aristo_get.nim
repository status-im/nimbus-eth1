# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Read vertex record on the layered Aristo DB delta architecture
## ==============================================================

{.push raises: [].}

import
  std/[sets, tables],
  stew/results,
  "."/[aristo_constants, aristo_desc, aristo_error]

type
  VidVtxPair* = object
    vid*: VertexID                 ## Table lookup vertex ID (if any)
    vtx*: VertexRef                ## Reference to vertex

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getVtxBackend*(
    db: AristoDb;
    vid: VertexID;
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the `backened` layer if available.
  let be = db.backend
  if not be.isNil:
    return be.getVtxFn vid

  err(GetVtxNotFound)

proc getKeyBackend*(
    db: AristoDb;
    vid: VertexID;
      ): Result[NodeKey,AristoError] =
  ## Get the merkle hash/key from the backend
  # key must not have been locally deleted (but not saved, yet)
  if vid notin db.top.dKey:
    let be = db.backend
    if not be.isNil:
      return be.getKeyFn vid

  err(GetKeyNotFound)


proc getVtxCascaded*(
    db: AristoDb;
    vid: VertexID;
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the top layer or the `backened` layer if available.
  let vtx = db.top.sTab.getOrDefault(vid, VertexRef(nil))
  if vtx != VertexRef(nil):
    return ok vtx

  db.getVtxBackend vid

proc getKeyCascaded*(
    db: AristoDb;
    vid: VertexID;
      ): Result[NodeKey,AristoError] =
  ## Get the Merkle hash/key from the top layer or the `backened` layer if
  ## available.
  let key = db.top.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
  if key != EMPTY_ROOT_KEY:
    return ok key

  db.getKeyBackend vid

proc getLeaf*(
    db: AristoDb;
    lky: LeafKey;
      ): Result[VidVtxPair,AristoError] =
  ## Get the vertex from the top layer by the `Patricia Trie` path. This
  ## function does not search on the `backend` layer.
  let vid = db.top.lTab.getOrDefault(lky, VertexID(0))
  if vid != VertexID(0):
    let vtx = db.top.sTab.getOrDefault(vid, VertexRef(nil))
    if vtx != VertexRef(nil):
      return ok VidVtxPair(vid: vid, vtx: vtx)

  err(GetTagNotFound)

# ---------

proc getVtx*(db: AristoDb; vid: VertexID): VertexRef =
  ## Variant of `getVtxCascaded()` returning `nil` on error (while
  ## ignoring the detailed error type information.)
  db.getVtxCascaded(vid).get(otherwise = VertexRef(nil))   

proc getVtx*(db: AristoDb; lky: LeafKey): VertexRef =
  ## Variant of `getLeaf()` returning `nil` on error (while
  ## ignoring the detailed error type information.)
  let rc = db.getLeaf lky
  if rc.isOk:
    return rc.value.vtx
  
proc getKey*(db: AristoDb; vid: VertexID): NodeKey =
  ## Variant of `getKeyCascaded()` returning `EMPTY_ROOT_KEY` on error (while
  ## ignoring the detailed error type information.)
  db.getKeyCascaded(vid).get(otherwise = EMPTY_ROOT_KEY)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

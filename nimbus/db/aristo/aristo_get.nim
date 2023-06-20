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
  std/tables,
  stew/results,
  "."/aristo_desc

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
      ): Result[HashKey,AristoError] =
  ## Get the merkle hash/key from the backend
  let be = db.backend
  if not be.isNil:
    return be.getKeyFn vid
  err(GetKeyNotFound)

# ------------------

proc getLeaf*(
    db: AristoDb;
    lty: LeafTie;
      ): Result[VidVtxPair,AristoError] =
  ## Get the vertex from the top layer by the `Patricia Trie` path. This
  ## function does not search on the `backend` layer.
  let vid = db.top.lTab.getOrVoid lty
  if not vid.isValid:
    return err(GetLeafNotFound)

  let vtx = db.top.sTab.getOrVoid vid
  if not vtx.isValid:
    return err(GetVtxNotFound)

  ok VidVtxPair(vid: vid, vtx: vtx)

proc getLeafVtx*(db: AristoDb; lty: LeafTie): VertexRef =
  ## Variant of `getLeaf()` returning `nil` on error (while ignoring the
  ## detailed error type information.)
  ##
  let rc = db.getLeaf lty
  if rc.isOk:
    return rc.value.vtx

# ------------------

proc getVtx*(db: AristoDb; vid: VertexID): VertexRef =
  ## Cascaded attempt to fetch a vertex from the top layer or the backend.
  ## The function returns `nil` on error or failure.
  ##
  if db.top.sTab.hasKey vid:
    # If the vertex is to be deleted on the backend, a `VertexRef(nil)` entry
    # is kept in the local table in which case it is OK to return this value.
    return db.top.sTab.getOrVoid vid
  let rc = db.getVtxBackend vid
  if rc.isOk:
    return rc.value
  VertexRef(nil)

proc getKey*(db: AristoDb; vid: VertexID): HashKey =
  ## Cascaded attempt to fetch a Merkle hash from the top layer or the backend.
  ## The function returns `VOID_HASH_KEY` on error or failure.
  ##
  if db.top.kMap.hasKey vid:
    # If the key is to be deleted on the backend, a `VOID_HASH_LABEL` entry
    # is kept on the local table in which case it is OK to return this value.
    return db.top.kMap.getOrVoid(vid).key
  let rc = db.getKeyBackend vid
  if rc.isOk:
    return rc.value
  VOID_HASH_KEY

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

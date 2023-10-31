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
  results,
  ./aristo_desc

type
  VidVtxPair* = object
    vid*: VertexID                 ## Table lookup vertex ID (if any)
    vtx*: VertexRef                ## Reference to vertex

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getIdgUBE*(
    db: AristoDbRef;
      ): Result[seq[VertexID],AristoError] =
  ## Get the ID generator state from the unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getIdgFn()
  err(GetIdgNotFound)

proc getFqsUBE*(
    db: AristoDbRef;
      ): Result[seq[(QueueID,QueueID)],AristoError] =
  ## Get the list of filter IDs unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getFqsFn()
  err(GetFqsNotFound)

proc getVtxUBE*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getVtxFn vid
  err GetVtxNotFound

proc getKeyUBE*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[HashKey,AristoError] =
  ## Get the merkle hash/key from the unfiltered backend if available.
  let be = db.backend
  if not be.isNil:
    return be.getKeyFn vid
  err GetKeyNotFound

proc getFilUBE*(
    db: AristoDbRef;
    qid: QueueID;
      ): Result[FilterRef,AristoError] =
  ## Get the filter from the unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getFilFn qid
  err GetFilNotFound

# ------------------

proc getIdgBE*(
    db: AristoDbRef;
      ): Result[seq[VertexID],AristoError] =
  ## Get the ID generator state the `backened` layer if available.
  if not db.roFilter.isNil:
    return ok(db.roFilter.vGen)
  db.getIdgUBE()

proc getVtxBE*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the (filtered) backened if available.
  if not db.roFilter.isNil and db.roFilter.sTab.hasKey vid:
    let vtx = db.roFilter.sTab.getOrVoid vid
    if vtx.isValid:
      return ok(vtx)
    return err(GetVtxNotFound)
  db.getVtxUBE vid

proc getKeyBE*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[HashKey,AristoError] =
  ## Get the merkle hash/key from the (filtered) backend if available.
  if not db.roFilter.isNil and db.roFilter.kMap.hasKey vid:
    let key = db.roFilter.kMap.getOrVoid vid
    if key.isValid:
      return ok(key)
    return err(GetKeyNotFound)
  db.getKeyUBE vid

# ------------------

proc getLeaf*(
    db: AristoDbRef;
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

proc getLeafVtx*(db: AristoDbRef; lty: LeafTie): VertexRef =
  ## Variant of `getLeaf()` returning `nil` on error (while ignoring the
  ## detailed error type information.)
  ##
  let rc = db.getLeaf lty
  if rc.isOk:
    return rc.value.vtx

# ------------------

proc getVtxRc*(db: AristoDbRef; vid: VertexID): Result[VertexRef,AristoError] =
  ## Cascaded attempt to fetch a vertex from the top layer or the backend.
  ##
  if db.top.sTab.hasKey vid:
    # If the vertex is to be deleted on the backend, a `VertexRef(nil)` entry
    # is kept in the local table in which case it is OK to return this value.
    let vtx = db.top.sTab.getOrVoid vid
    if vtx.isValid:
      return ok(vtx)
    return err(GetVtxNotFound)
  db.getVtxBE vid

proc getVtx*(db: AristoDbRef; vid: VertexID): VertexRef =
  ## Cascaded attempt to fetch a vertex from the top layer or the backend.
  ## The function returns `nil` on error or failure.
  ##
  let rc = db.getVtxRc vid
  if rc.isOk:
    return rc.value
  VertexRef(nil)

proc getKeyRc*(db: AristoDbRef; vid: VertexID): Result[HashKey,AristoError] =
  ## Cascaded attempt to fetch a Merkle hash from the top layer or the backend.
  ##
  if db.top.kMap.hasKey vid:
    # If the key is to be deleted on the backend, a `VOID_HASH_LABEL` entry
    # is kept on the local table in which case it is OK to return this value.
    let lbl = db.top.kMap.getOrVoid vid
    if lbl.isValid:
      return ok lbl.key
    return err(GetKeyTempLocked)
  db.getKeyBE vid

proc getKey*(db: AristoDbRef; vid: VertexID): HashKey =
  ## Cascaded attempt to fetch a vertex from the top layer or the backend.
  ## The function returns `nil` on error or failure.
  ##
  db.getKeyRc(vid).valueOr:
    return VOID_HASH_KEY

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

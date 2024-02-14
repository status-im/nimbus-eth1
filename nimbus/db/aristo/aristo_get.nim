# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  "."/[aristo_desc, aristo_layers]

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
  ## Get the leaf path from the cache layers and look up the database for a
  ## leaf node.
  let vid = db.lTab.getOrVoid lty
  if not vid.isValid:
    return err(GetLeafNotFound)

  block body:
    let vtx = db.layersGetVtx(vid).valueOr:
      break body
    if vtx.isValid:
      return ok(VidVtxPair(vid: vid, vtx: vtx))

  # The leaf node cannot be on the backend. It was produced by a `merge()`
  # action. So this is a system problem.
  err(GetLeafMissing)

proc getLeafVtx*(db: AristoDbRef; lty: LeafTie): VertexRef =
  ## Variant of `getLeaf()` returning `nil` on error (while ignoring the
  ## detailed error type information.)
  ##
  let rc = db.getLeaf lty
  if rc.isOk:
    return rc.value.vtx

# ------------------

proc getVtxRc*(db: AristoDbRef; vid: VertexID): Result[VertexRef,AristoError] =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ##
  block body:
    # If the vertex marked is to be deleted on the backend, a `VertexRef(nil)`
    # entry is kept in the local table in which case it isis returned as the
    # error symbol `GetVtxNotFound`.
    let vtx = db.layersGetVtx(vid).valueOr:
      break body
    if vtx.isValid:
      return ok vtx
    else:
      return err(GetVtxNotFound)

  db.getVtxBE vid

proc getVtx*(db: AristoDbRef; vid: VertexID): VertexRef =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ## The function returns `nil` on error or failure.
  ##
  db.getVtxRc(vid).valueOr: VertexRef(nil)


proc getKeyRc*(db: AristoDbRef; vid: VertexID): Result[HashKey,AristoError] =
  ## Cascaded attempt to fetch a Merkle hash from the cache layers or the
  ## backend.
  ##
  block body:
    let key = db.layersGetKey(vid).valueOr:
      break body
    # If there is a zero key value, the entry is either marked for being
    # updated or for deletion on the database. So check below.
    if key.isValid:
      return ok key

    # The zero key value does not refer to an update mark if there is no
    # valid vertex (either on the cache or the backend whatever comes first.)
    let vtx = db.layersGetVtx(vid).valueOr:
      # There was no vertex on the cache. So there must be one the backend (the
      # reason for the key lable to exists, at all.)
      return err(GetKeyUpdateNeeded)
    if vtx.isValid:
      return err(GetKeyUpdateNeeded)
    else:
      # The vertex is to be deleted. So is the value key.
      return err(GetKeyNotFound)

  db.getKeyBE vid

proc getKey*(db: AristoDbRef; vid: VertexID): HashKey =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ## The function returns `nil` on error or failure.
  ##
  db.getKeyRc(vid).valueOr: VOID_HASH_KEY

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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

proc getTuvUbe*(
    db: AristoDbRef;
      ): Result[VertexID,AristoError] =
  ## Get the ID generator state from the unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getTuvFn()
  err(GetTuvNotFound)

proc getLstUbe*(
    db: AristoDbRef;
      ): Result[SavedState,AristoError] =
  ## Get the last saved state
  let be = db.backend
  if not be.isNil:
    return be.getLstFn()
  err(GetLstNotFound)

proc getVtxUbe*(
    db: AristoDbRef;
    rvid: RootedVertexID;
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getVtxFn rvid
  err GetVtxNotFound

proc getKeyUbe*(
    db: AristoDbRef;
    rvid: RootedVertexID;
      ): Result[HashKey,AristoError] =
  ## Get the Merkle hash/key from the unfiltered backend if available.
  let be = db.backend
  if not be.isNil:
    return be.getKeyFn rvid
  err GetKeyNotFound

# ------------------

proc getTuvBE*(
    db: AristoDbRef;
      ): Result[VertexID,AristoError] =
  ## Get the ID generator state the `backened` layer if available.
  if not db.balancer.isNil:
    return ok(db.balancer.vTop)
  db.getTuvUbe()

proc getVtxBE*(
    db: AristoDbRef;
    rvid: RootedVertexID;
      ): Result[(VertexRef, int),AristoError] =
  ## Get the vertex from the (filtered) backened if available.
  if not db.balancer.isNil:
    db.balancer.sTab.withValue(rvid, w):
      if w[].isValid:
        return ok (w[], -1)
      return err(GetVtxNotFound)
  ok (? db.getVtxUbe rvid, -2)

proc getKeyBE*(
    db: AristoDbRef;
    rvid: RootedVertexID;
      ): Result[(HashKey, int),AristoError] =
  ## Get the merkle hash/key from the (filtered) backend if available.
  if not db.balancer.isNil:
    db.balancer.kMap.withValue(rvid, w):
      if w[].isValid:
        return ok((w[], -1))
      return err(GetKeyNotFound)
  ok ((?db.getKeyUbe rvid), -2)

# ------------------

proc getVtxRc*(
    db: AristoDbRef;
    rvid: RootedVertexID
      ): Result[(VertexRef, int),AristoError] =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ##
  block body:
    # If the vertex marked is to be deleted on the backend, a `VertexRef(nil)`
    # entry is kept in the local table in which case it is returned as the
    # error symbol `GetVtxNotFound`.
    let vtx = db.layersGetVtx(rvid).valueOr:
      break body
    if vtx[0].isValid:
      return ok vtx
    else:
      return err(GetVtxNotFound)

  db.getVtxBE rvid

proc getVtx*(db: AristoDbRef; rvid: RootedVertexID): VertexRef =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ## The function returns `nil` on error or failure.
  ##
  db.getVtxRc(rvid).valueOr((VertexRef(nil), 0))[0]


proc getKeyRc*(db: AristoDbRef; rvid: RootedVertexID): Result[(HashKey, int),AristoError] =
  ## Cascaded attempt to fetch a Merkle hash from the cache layers or the
  ## backend. This function will never return a `VOID_HASH_KEY` but rather
  ## some `GetKeyNotFound` or `GetKeyUpdateNeeded` error.
  ##
  block body:
    let key = db.layersGetKey(rvid).valueOr:
      break body
    # If there is a zero key value, the entry is either marked for being
    # updated or for deletion on the database. So check below.
    if key[0].isValid:
      return ok key

    # The zero key value does not refer to an update mark if there is no
    # valid vertex (either on the cache or the backend whatever comes first.)
    let vtx = db.layersGetVtx(rvid).valueOr:
      # There was no vertex on the cache. So there must be one the backend (the
      # reason for the key lable to exists, at all.)
      return err(GetKeyUpdateNeeded)
    if vtx[0].isValid:
      return err(GetKeyUpdateNeeded)
    else:
      # The vertex is to be deleted. So is the value key.
      return err(GetKeyNotFound)

  db.getKeyBE rvid

proc getKey*(db: AristoDbRef; rvid: RootedVertexID): HashKey =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ## The function returns `nil` on error or failure.
  ##
  (db.getKeyRc(rvid).valueOr((VOID_HASH_KEY, 0)))[0]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

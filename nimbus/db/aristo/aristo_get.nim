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

proc getIdgUbe*(
    db: AristoDbRef;
      ): Result[seq[VertexID],AristoError] =
  ## Get the ID generator state from the unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getIdgFn()
  err(GetIdgNotFound)

proc getFqsUbe*(
    db: AristoDbRef;
      ): Result[seq[(QueueID,QueueID)],AristoError] =
  ## Get the list of filter IDs unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getFqsFn()
  err(GetFqsNotFound)

proc getVtxUbe*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the unfiltered backened if available.
  let be = db.backend
  if not be.isNil:
    return be.getVtxFn vid
  err GetVtxNotFound

proc getKeyUbe*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[HashKey,AristoError] =
  ## Get the Merkle hash/key from the unfiltered backend if available.
  let be = db.backend
  if not be.isNil:
    return be.getKeyFn vid
  err GetKeyNotFound

proc getFilUbe*(
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
  db.getIdgUbe()

proc getVtxBE*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the (filtered) backened if available.
  if not db.roFilter.isNil:
    db.roFilter.sTab.withValue(vid, w):
      if w[].isValid:
        return ok(w[])
      return err(GetVtxNotFound)
  db.getVtxUbe vid

proc getKeyBE*(
    db: AristoDbRef;
    vid: VertexID;
      ): Result[HashKey,AristoError] =
  ## Get the merkle hash/key from the (filtered) backend if available.
  if not db.roFilter.isNil:
    db.roFilter.kMap.withValue(vid, w):
      if w[].isValid:
        return ok(w[])
      return err(GetKeyNotFound)
  db.getKeyUbe vid

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
  ## backend. This function will never return a `VOID_HASH_KEY` but rather
  ## some `GetKeyNotFound` or `GetKeyUpdateNeeded` error.
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

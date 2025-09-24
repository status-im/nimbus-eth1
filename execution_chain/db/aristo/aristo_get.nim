# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  results,
  "."/[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getLstBe*(
    db: AristoDbRef;
      ): Result[SavedState,AristoError] =
  ## Get the last saved state
  db.getLstFn()

proc getVtxBe*(
    db: AristoDbRef;
    rvid: RootedVertexID;
    flags: set[GetVtxFlag] = {};
      ): Result[VertexRef,AristoError] =
  ## Get the vertex from the backened if available.
  db.getVtxFn(rvid, flags)

proc getKeyBe*(
    db: AristoDbRef;
    rvid: RootedVertexID;
    flags: set[GetVtxFlag];
      ): Result[(HashKey, VertexRef),AristoError] =
  ## Get the Merkle hash/key from the backend if available.
  db.getKeyFn(rvid, flags)

# ------------------

proc getVtxRc*(
    db: AristoTxRef;
    rvid: RootedVertexID;
    flags: set[GetVtxFlag] = {};
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

  ok (?db.db.getVtxBe(rvid, flags), dbLevel)

proc getVtx*(db: AristoTxRef; rvid: RootedVertexID, flags: set[GetVtxFlag] = {}): VertexRef =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ## The function returns `nil` on error or failure.
  ##
  db.getVtxRc(rvid).valueOr((VertexRef(nil), 0))[0]

proc getKeyRc*(
    db: AristoTxRef; rvid: RootedVertexID, flags: set[GetVtxFlag]): Result[((HashKey, VertexRef), int),AristoError] =
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
      return ok ((key[0], nil), key[1])

    # The zero key value does not refer to an update mark if there is no
    # valid vertex (either on the cache or the backend whatever comes first.)
    let vtx = db.layersGetVtx(rvid).valueOr:
      # There was no vertex on the cache. So there must be one the backend (the
      # reason for the key label to exists, at all.)
      return err(GetKeyNotFound)

    # If the vertex came from a lower level than the baseTxFrame it means that
    # there might be a newer value in the database so we fetch it directly from the
    # database in this case.
    if vtx[1] < db.db.baseTxFrame().level:
      break body

    if vtx[0].isValid:
      return ok ((VOID_HASH_KEY, vtx[0]), vtx[1])
    else:
      # The vertex is to be deleted. So is the value key.
      return err(GetKeyNotFound)

  ok (?db.db.getKeyBe(rvid, flags), dbLevel)

proc getKey*(db: AristoTxRef; rvid: RootedVertexID): HashKey =
  ## Cascaded attempt to fetch a vertex from the cache layers or the backend.
  ## The function returns `nil` on error or failure.
  ##
  (db.getKeyRc(rvid, {}).valueOr(((VOID_HASH_KEY, nil), 0)))[0][0]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

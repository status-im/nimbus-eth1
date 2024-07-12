# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie builder, raw node insertion
## ======================================================
##
## This module merges `PathID` values as hexary lookup paths into the
## `Patricia Trie`. When changing vertices (aka nodes without Merkle hashes),
## associated (but separated) Merkle hashes will be deleted unless locked.
## Instead of deleting locked hashes error handling is applied.
##
## Also, nodes (vertices plus merkle hashes) can be added which is needed for
## boundary proofing after `snap/1` download. The vertices are split from the
## nodes and stored as-is on the table holding `Patricia Trie` entries. The
##  hashes are stored iin a separate table and the vertices are labelled
## `locked`.

{.push raises: [].}

import
  std/typetraits,
  eth/common,
  results,
  "."/[aristo_desc, aristo_hike, aristo_layers, aristo_vid],
  ./aristo_merge/merge_payload_helper

const
  MergeNoAction = {MergeLeafPathCachedAlready, MergeLeafPathOnBackendAlready}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeAccountRecord*(
    db: AristoDbRef;                   # Database, top layer
    accPath: Hash256;          # Even nibbled byte path
    accRec: AristoAccount;             # Account data
      ): Result[bool,AristoError] =
  ## Merge the  key-value-pair argument `(accKey,accRec)` as an account
  ## ledger value, i.e. the the sub-tree starting at `VertexID(1)`.
  ##
  ## On success, the function returns `true` if the `accRec` argument was
  ## not on the database already or different from `accRec`, and `false`
  ## otherwise.
  ##
  let
    pyl =  PayloadRef(pType: AccountData, account: accRec)
    rc = db.mergePayloadImpl(VertexID(1), accPath.data, pyl)
  if rc.isOk:
    db.layersPutAccPayload(accPath, pyl)
    ok true
  elif rc.error in MergeNoAction:
    ok false
  else:
    err(rc.error)


proc mergeGenericData*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
      ): Result[bool,AristoError] =
  ## Variant of `mergeXXX()` for generic sub-trees, i.e. for arguments
  ## `root` greater than `VertexID(1)` and smaller than `LEAST_FREE_VID`.
  ##
  ## On success, the function returns `true` if the `data` argument was merged
  ## into the database ot updated, and `false` if it was on the database
  ## already.
  ##
  # Verify that `root` is neither an accounts tree nor a strorage tree.
  if not root.isValid:
    return err(MergeRootVidMissing)
  elif root == VertexID(1):
    return err(MergeAccRootNotAccepted)
  elif LEAST_FREE_VID <= root.distinctBase:
    return err(MergeStoRootNotAccepted)

  let
    pyl = PayloadRef(pType: RawData, rawBlob: @data)
    rc = db.mergePayloadImpl(root, path, pyl)
  if rc.isOk:
    ok true
  elif rc.error in MergeNoAction:
    ok false
  else:
    err(rc.error)


proc mergeStorageData*(
    db: AristoDbRef;                   # Database, top layer
    accPath: Hash256;          # Needed for accounts payload
    stoPath: Hash256;          # Storage data path (aka key)
    stoData: UInt256;          # Storage data payload value
      ): Result[void,AristoError] =
  ## Store the `stoData` data argument on the storage area addressed by
  ## `(accPath,stoPath)` where `accPath` is the account key (into the MPT)
  ## and `stoPath`  is the slot path of the corresponding storage area.
  ##
  var
    path = NibblesBuf.fromBytes(accPath.data)
    next = VertexID(1)
    vtx: VertexRef
    touched: array[NibblesBuf.high(), VertexID]
    pos: int

  template resetKeys() =
    # Reset cached hashes of touched verticies
    for i in 0 ..< pos:
      db.layersResKey((VertexID(1), touched[pos - i - 1]))

  while path.len > 0:
    touched[pos] = next
    pos += 1

    (vtx, path, next) = ?step(path, (VertexID(1), next), db)

    if vtx.vType == Leaf:
      let
        stoID = vtx.lData.stoID

        # Provide new storage ID when needed
        useID = if stoID.isValid: stoID else: db.vidFetch()

        # Call merge
        pyl = PayloadRef(pType: StoData, stoData: stoData)
        rc = db.mergePayloadImpl(useID, stoPath.data, pyl)

      if rc.isOk:
        # Mark account path Merkle keys for update
        resetKeys()


        if not stoID.isValid:
          # Make sure that there is an account that refers to that storage trie
          let leaf = vtx.dup # Dup on modify
          leaf.lData.stoID = useID
          db.layersPutAccPayload(accPath, leaf.lData)
          db.layersPutVtx((VertexID(1), touched[pos - 1]), leaf)

        return ok()

      elif rc.error in MergeNoAction:
        assert stoID.isValid         # debugging only
        return ok()

      return err(rc.error)

  err(MergeHikeFailed)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

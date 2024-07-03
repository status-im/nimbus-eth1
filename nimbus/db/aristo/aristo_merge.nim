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
  "."/[aristo_desc, aristo_fetch, aristo_layers, aristo_utils, aristo_vid],
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
  ## Merge the  key-value-pair argument `(accKey,accPayload)` as an account
  ## ledger value, i.e. the the sub-tree starting at `VertexID(1)`.
  ##
  ## The payload argument `accPayload` must have the `storageID` field either
  ## unset/invalid or referring to a existing vertex which will be assumed
  ## to be a storage tree.
  ##
  ## On success, the function returns `true` if the `accPayload` argument was
  ## merged into the database ot updated, and `false` if it was on the database
  ## already.
  ##
  let
    pyl =  PayloadRef(pType: AccountData, account: accRec)
    rc = db.mergePayloadImpl(VertexID(1), accPath.data, pyl)
  if rc.isOk:
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
    stoPath: openArray[byte];          # Storage data path (aka key)
    stoData: openArray[byte];          # Storage data payload value
      ): Result[void,AristoError] =
  ## Store the `stoData` data argument on the storage area addressed by
  ## `(accPath,stoPath)` where `accPath` is the account key (into the MPT)
  ## and `stoPath`  is the slot path of the corresponding storage area.
  ##
  let
    accHike = db.fetchAccountHike(accPath).valueOr:
      if error == FetchAccInaccessible:
        return err(MergeStoAccMissing)
      return err(error)
    wpAcc = accHike.legs[^1].wp
    stoID = wpAcc.vtx.lData.stoID

    # Provide new storage ID when needed
    useID = if stoID.isValid: stoID else: db.vidFetch()

    # Call merge
    pyl = PayloadRef(pType: RawData, rawBlob: @stoData)
    rc = db.mergePayloadImpl(useID, stoPath, pyl)

  if rc.isOk:
    # Mark account path Merkle keys for update
    db.updateAccountForHasher accHike

    if stoID.isValid:
      return ok()

    else:
      # Make sure that there is an account that refers to that storage trie
      let leaf = wpAcc.vtx.dup # Dup on modify
      leaf.lData.stoID = useID
      db.layersPutStoID(accPath, useID)
      db.layersUpdateVtx((accHike.root, wpAcc.vid), leaf)
      return ok()

  elif rc.error in MergeNoAction:
    assert stoID.isValid         # debugging only
    return ok()

  # Error: mark account path Merkle keys for update
  db.updateAccountForHasher accHike
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

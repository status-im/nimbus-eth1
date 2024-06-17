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
  eth/common,
  results,
  "."/[aristo_desc, aristo_path, aristo_utils, aristo_vid],
  ./aristo_merge/[merge_payload_helper, merge_proof]

export
  merge_proof

const
  MergeNoAction = {MergeLeafPathCachedAlready, MergeLeafPathOnBackendAlready}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergePayload*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Even nibbled byte path
    payload: PayloadRef;               # Payload value
    accPath = VOID_PATH_ID;            # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Merge the `(root,path)` arguments into the MPT starting at `root`. The
  ## argument`path` is used as key to address the leaf vertex with the
  ## payload argument `payload`. It is stored or updated on the database `db`
  ## accordingly.
  ##
  ## If the `root` argument is `VertexID(1)` the payload argument must be of
  ## type `AccountData`. In that case, the `storageID` field of the leaf entry
  ## must refer to an existing vertex if it holds a valid vertex ID. The
  ## argument `accPath` must be void.
  ##
  ## Otherwise, if the `root` argument belongs to a well known sub trie (i.e.
  ## it does not exceed `LEAST_FREE_VID`) the `accPath` argument is ignored
  ## and the entry will just be merged.  The argument `accPath` must be void.
  ##
  ## Otherwise, a valid `accPath` (i.e. different from `VOID_PATH_ID`.) is
  ## required leading to an account leaf entry (starting at `VertexID(1)`) the
  ## leaf of which must have payload type `AccountData`. If the  payload field
  ## `storageID` does not have a valid entry, a new sub-trie is created and
  ## the `storageID` field is updated on disk.
  ##
  let
    lty = LeafTie(root: root, path: ? path.pathToTag)
    rc = db.mergePayloadImpl(lty, payload, accPath)
  if rc.isOk:
    ok true
  elif rc.error in MergeNoAction:
    ok false
  else:
    err(rc.error)

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
    accPath: PathID;                   # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(root,path)` arguments instead of a `LeafTie`.
  ## The argument `data` is stored as-is as a `RawData` payload value.
  let pyl = PayloadRef(pType: RawData, rawBlob: @data)
  db.mergePayload(root, path, pyl, accPath)

# --------------

proc mergeAccountPayload*(
    db: AristoDbRef;                   # Database, top layer
    accKey: openArray[byte];          # Even nibbled byte path
    accPayload: AristoAccount;         # Payload value
      ): Result[bool,AristoError] =
  ## Merge the  key-value-pair argument `(accKey,accPayload)` as an account
  ## ledger value, i.e. the the sub-tree starting at `VertexID(1)`.
  ##
  ## The payload argument `accPayload` must have the `storageID` field either
  ## unset/invalid or referring to a existing vertex which will be assumed
  ## to be a storage tree.
  ##
  let
    lty = LeafTie(root: VertexID(1), path: ? accKey.pathToTag)
    pyl =  PayloadRef(pType: AccountData, account: accPayload)
    rc = db.mergePayloadImpl(lty, pyl, VOID_PATH_ID)
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
  let
    pyl = PayloadRef(pType: RawData, rawBlob: @data)
    lty = LeafTie(root: root, path: ? path.pathToTag)
    rc = db.mergePayloadImpl(lty, pyl, VOID_PATH_ID)
  if rc.isOk:
    ok true
  elif rc.error in MergeNoAction:
    ok false
  else:
    err(rc.error)



proc mergeStorageData*(
    db: AristoDbRef;                   # Database, top layer
    stoKey: openArray[byte];           # Storage data path (aka key)
    stoData: openArray[byte];          # Storage data payload value
    accPath: PathID;                   # Needed for accounts payload
      ): Result[VertexID,AristoError] =
  ## Merge the  key-value-pair argument `(stoKey,stoData)` as a storage value.
  ## This means, the root vertex will be derived from the `accPath` argument,
  ## the Patricia tree path for the storage tree is given by `stoKey` and the
  ## leaf value with the payload will be stored as a `PayloadRef` object of
  ## type `RawData`.
  ##
  ## If the storage tree does not exist yet it will be created and the
  ## payload leaf accessed by `accPath` will be updated with the storage
  ## tree vertex ID.
  ##
  ## The function returns the new vertex ID if a new storage tree was created,
  ## otherwise `VertexID(0)`.
  ##
  let
    stoTag = ? stoKey.pathToTag()
    wp = ? db.registerAccountForUpdate accPath
    stoID = wp.vtx.lData.account.storageID

    # Provide new storage ID when needed
    useID = if stoID.isValid: stoID else: db.vidFetch()

    # Call merge
    lty = LeafTie(root: useID, path: stoTag)
    pyl = PayloadRef(pType: RawData, rawBlob: @stoData)
    rc = db.mergePayloadImpl(lty, pyl, accPath)

  if rc.isOk:
    if rc.value:
      doAssert not stoID.isValid
      return ok useID
    doAssert stoID.isValid
    return ok VertexID(0)

  elif rc.error in MergeNoAction:
    doAssert stoID.isValid
    return ok VertexID(0)

  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

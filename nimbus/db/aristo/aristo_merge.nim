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
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_layers, aristo_vid]


proc layersPutLeaf(
    db: AristoDbRef, rvid: RootedVertexID, path: NibblesBuf, payload: LeafPayload
): VertexRef =
  let vtx = VertexRef(vType: Leaf, pfx: path, lData: payload)
  db.layersPutVtx(rvid, vtx)
  vtx

proc mergePayloadImpl(
    db: AristoDbRef, # Database, top layer
    root: VertexID, # MPT state root
    path: openArray[byte], # Leaf item to add to the database
    leaf: Opt[VertexRef],
    payload: LeafPayload, # Payload value
): Result[(VertexRef, VertexRef, VertexRef), AristoError] =
  ## Merge the argument `(root,path)` key-value-pair into the top level vertex
  ## table of the database `db`. The `path` argument is used to address the
  ## leaf vertex with the payload. It is stored or updated on the database
  ## accordingly.
  ##
  var
    path = NibblesBuf.fromBytes(path)
    cur = root
    (vtx, _) = db.getVtxRc((root, cur)).valueOr:
      if error != GetVtxNotFound:
        return err(error)

      # We're at the root vertex and there is no data - this must be a fresh
      # VertexID!
      return ok (db.layersPutLeaf((root, cur), path, payload), nil, nil)
    steps: ArrayBuf[NibblesBuf.high + 1, VertexID]

  template resetKeys() =
    # Reset cached hashes of touched verticies
    for i in 1..steps.len:
      db.layersResKey((root, steps[^i]))

  while path.len > 0:
    # Clear existing merkle keys along the traversal path
    steps.add cur

    let n = path.sharedPrefixLen(vtx.pfx)
    case vtx.vType
    of Leaf:
      let res =
        if n == vtx.pfx.len:
          # Same path - replace the current vertex with a new payload

          if vtx.lData == payload:
            return err(MergeNoAction)

          let leafVtx = if root == VertexID(1):
            var payload = payload.dup()
            # TODO can we avoid this hack? it feels like the caller should already
            #      have set an appropriate stoID - this "fixup" feels risky,
            #      specially from a caching point of view
            payload.stoID = vtx.lData.stoID
            db.layersPutLeaf((root, cur), path, payload)
          else:
            db.layersPutLeaf((root, cur), path, payload)
          (leafVtx, nil, nil)
        else:
          # Turn leaf into a branch (or extension) then insert the two leaves
          # into the branch
          let branch = VertexRef(vType: Branch, pfx: path.slice(0, n))
          let other = block: # Copy of existing leaf node, now one level deeper
            let local = db.vidFetch()
            branch.bVid[vtx.pfx[n]] = local
            db.layersPutLeaf((root, local), vtx.pfx.slice(n + 1), vtx.lData)

          let leafVtx = block: # Newly inserted leaf node
            let local = db.vidFetch()
            branch.bVid[path[n]] = local
            db.layersPutLeaf((root, local), path.slice(n + 1), payload)

          # Put the branch at the vid where the leaf was
          db.layersPutVtx((root, cur), branch)

          # We need to return vtx here because its pfx member hasn't yet been
          # sliced off and is therefore shared with the hike
          (leafVtx, vtx, other)

      resetKeys()
      return ok(res)
    of Branch:
      if vtx.pfx.len == n:
        # The existing branch is a prefix of the new entry
        let
          nibble = path[vtx.pfx.len]
          next = vtx.bVid[nibble]

        if next.isValid:
          cur = next
          path = path.slice(n + 1)
          vtx =
            if leaf.isSome and leaf[].isValid and leaf[].pfx == path:
              leaf[]
            else:
              (?db.getVtxRc((root, next)))[0]

        else:
          # There's no vertex at the branch point - insert the payload as a new
          # leaf and update the existing branch
          let
            local = db.vidFetch()
            leafVtx = db.layersPutLeaf((root, local), path.slice(n + 1), payload)
            brDup = vtx.dup()

          brDup.bVid[nibble] = local
          db.layersPutVtx((root, cur), brDup)

          resetKeys()
          return ok((leafVtx, nil, nil))
      else:
        # Partial path match - we need to split the existing branch at
        # the point of divergence, inserting a new branch
        let branch = VertexRef(vType: Branch, pfx: path.slice(0, n))
        block: # Copy the existing vertex and add it to the new branch
          let local = db.vidFetch()
          branch.bVid[vtx.pfx[n]] = local

          db.layersPutVtx(
            (root, local),
            VertexRef(vType: Branch, pfx: vtx.pfx.slice(n + 1), bVid: vtx.bVid),
          )

        let leafVtx = block: # add the new entry
          let local = db.vidFetch()
          branch.bVid[path[n]] = local
          db.layersPutLeaf((root, local), path.slice(n + 1), payload)

        db.layersPutVtx((root, cur), branch)

        resetKeys()
        return ok((leafVtx, nil, nil))

  err(MergeHikeFailed)

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
    pyl =  LeafPayload(pType: AccountData, account: accRec)
    updated = db.mergePayloadImpl(
        VertexID(1), accPath.data, db.cachedAccLeaf(accPath), pyl).valueOr:
      if error == MergeNoAction:
        return ok false
      return err(error)

  # Update leaf cache both of the merged value and potentially the displaced
  # leaf resulting from splitting a leaf into a branch with two leaves
  db.layersPutAccLeaf(accPath, updated[0])
  if updated[1].isValid:
    let otherPath = Hash32(getBytes(
      NibblesBuf.fromBytes(accPath.data).replaceSuffix(updated[1].pfx)))
    db.layersPutAccLeaf(otherPath, updated[2])

  ok true

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
    pyl = LeafPayload(pType: RawData, rawBlob: @data)

  discard db.mergePayloadImpl(root, path, Opt.none(VertexRef), pyl).valueOr:
    if error == MergeNoAction:
      return ok false
    return err error

  ok true

proc mergeStorageData*(
    db: AristoDbRef;                   # Database, top layer
    accPath: Hash256;                  # Needed for accounts payload
    stoPath: Hash256;                  # Storage data path (aka key)
    stoData: UInt256;                  # Storage data payload value
      ): Result[void,AristoError] =
  ## Store the `stoData` data argument on the storage area addressed by
  ## `(accPath,stoPath)` where `accPath` is the account key (into the MPT)
  ## and `stoPath`  is the slot path of the corresponding storage area.
  ##
  var accHike: Hike
  db.fetchAccountHike(accPath,accHike).isOkOr:
    return err(MergeStoAccMissing)

  let
    stoID = accHike.legs[^1].wp.vtx.lData.stoID

    # Provide new storage ID when needed
    useID =
      if stoID.isValid: stoID                     # Use as is
      elif stoID.vid.isValid: (true, stoID.vid)   # Re-use previous vid
      else: (true, db.vidFetch())                 # Create new vid
    mixPath = mixUp(accPath, stoPath)
    # Call merge
    pyl = LeafPayload(pType: StoData, stoData: stoData)
    updated = db.mergePayloadImpl(
        useID.vid, stoPath.data, db.cachedStoLeaf(mixPath), pyl).valueOr:
      if error == MergeNoAction:
        assert stoID.isValid         # debugging only
        return ok()

      return err(error)

  # Mark account path Merkle keys for update
  db.layersResKeys(accHike)

  # Update leaf cache both of the merged value and potentially the displaced
  # leaf resulting from splitting a leaf into a branch with two leaves
  db.layersPutStoLeaf(mixPath, updated[0])

  if updated[1].isValid:
    let otherPath = Hash32(getBytes(
      NibblesBuf.fromBytes(stoPath.data).replaceSuffix(updated[1].pfx)))
    db.layersPutStoLeaf(mixUp(accPath, otherPath), updated[2])

  if not stoID.isValid:
    # Make sure that there is an account that refers to that storage trie
    let leaf = accHike.legs[^1].wp.vtx.dup # Dup on modify
    leaf.lData.stoID = useID
    db.layersPutAccLeaf(accPath, leaf)
    db.layersPutVtx((VertexID(1), accHike.legs[^1].wp.vid), leaf)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

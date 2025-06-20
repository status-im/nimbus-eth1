# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
## This module merges Hash32 values as hexary lookup paths into the
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
  eth/common/hashes,
  results,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_layers, aristo_vid]

proc layersPutLeaf[T](
    db: AristoTxRef, rvid: RootedVertexID, path: NibblesBuf, payload: T
): auto =
  when T is UInt256:
    let vtx = StoLeafRef.init(path, payload)
  else:
    let vtx = AccLeafRef.init(path, payload, default(StorageID))

  db.layersPutVtx(rvid, vtx)
  vtx

proc mergePayloadImpl[LeafType, T](
    db: AristoTxRef, # Database, top layer
    root: VertexID, # MPT state root
    path: Hash32, # Leaf item to add to the database
    leaf: Opt[LeafType],
    payload: T, # Payload value
): Result[(LeafType, VertexRef, LeafType), AristoError] =
  ## Merge the argument `(root,path)` key-value-pair into the top level vertex
  ## table of the database `db`. The `path` argument is used to address the
  ## leaf vertex with the payload. It is stored or updated on the database
  ## accordingly.
  ##
  var
    path = NibblesBuf.fromBytes(path.data)
    pos = 0
    cur = root
    (vtx, _) = db.getVtxRc((root, cur)).valueOr:
      if error != GetVtxNotFound:
        return err(error)

      # We're at the root vertex and there is no data - this must be a fresh
      # VertexID!
      return ok (db.layersPutLeaf((root, cur), path, payload), nil, nil)
    vids: ArrayBuf[NibblesBuf.high + 1, VertexID]
    vtxs: ArrayBuf[NibblesBuf.high + 1, VertexRef]

  template resetKeys() =
    # Reset cached hashes of touched verticies
    for i in 1..vids.len:
      db.layersResKey((root, vids[^i]), vtxs[^i])

  while pos < path.len:
    # Clear existing merkle keys along the traversal path
    var psuffix = path.slice(pos)
    let n = psuffix.sharedPrefixLen(vtx.pfx)
    case vtx.vType
    of Leaves:
      let res =
        if n == vtx.pfx.len:
          # Same path - replace the current vertex with a new payload

          when payload is AristoAccount:
            if AccLeafRef(vtx).account == payload:
              return err(MergeNoAction)
            let leafVtx = db.layersPutLeaf((root, cur), psuffix, payload)
            leafVtx.stoID = AccLeafRef(vtx).stoID

          else:
            if StoLeafRef(vtx).stoData == payload:
              return err(MergeNoAction)
            let leafVtx = db.layersPutLeaf((root, cur), psuffix, payload)
          (leafVtx, nil, nil)
        else:
          # Turn leaf into a branch (or extension) then insert the two leaves
          # into the branch
          let
            startVid =
              if root == STATE_ROOT_VID:
                db.accVidFetch(path.slice(0, pos + n) & NibblesBuf.nibble(0), 16)
              else:
                db.vidFetch(16)
            branch =
              if n > 0:
                ExtBranchRef.init(psuffix.slice(0, n), startVid, 0)
              else:
                BranchRef.init(startVid, 0)
          let other = block: # Copy of existing leaf node, now one level deeper
            let
              local = branch.setUsed(vtx.pfx[n], true)
              pfx = vtx.pfx.slice(n + 1)
            when payload is AristoAccount:
              let accVtx = db.layersPutLeaf((root, local), pfx, AccLeafRef(vtx).account)
              accVtx.stoID = AccLeafRef(vtx).stoID
              accVtx
            else:
              db.layersPutLeaf((root, local), pfx, StoLeafRef(vtx).stoData)

          let leafVtx = block: # Newly inserted leaf node
            let local = branch.setUsed(psuffix[n], true)
            db.layersPutLeaf((root, local), psuffix.slice(n + 1), payload)

          # Put the branch at the vid where the leaf was
          db.layersPutVtx((root, cur), branch)

          # We need to return vtx here because its pfx member hasn't yet been
          # sliced off and is therefore shared with the hike
          (leafVtx, vtx, other)

      resetKeys()
      return ok(res)
    of Branches:
      if vtx.pfx.len == n:
        # The existing branch is a prefix of the new entry
        let
          nibble = psuffix[vtx.pfx.len]
          next = BranchRef(vtx).bVid(nibble)

        if next.isValid:
          vids.add cur
          vtxs.add vtx
          cur = next
          psuffix = psuffix.slice(n + 1)
          pos += n + 1
          vtx =
            if leaf.isSome and leaf[].isValid and leaf[].pfx == psuffix:
              leaf[]
            else:
              (?db.getVtxRc((root, next)))[0]
        else:
          # There's no vertex at the branch point - insert the payload as a new
          # leaf and update the existing branch

          let brDup = vtx.dup()
          let local = BranchRef(brDup).setUsed(nibble, true)
          db.layersPutVtx((root, cur), brDup)

          let leafVtx = db.layersPutLeaf((root, local), psuffix.slice(n + 1), payload)

          resetKeys()
          return ok((leafVtx, nil, nil))
      else:
        # Partial path match - we need to split the existing branch at
        # the point of divergence, inserting a new branch
        let
          startVid =
            if root == STATE_ROOT_VID:
              db.accVidFetch(path.slice(0, pos + n) & NibblesBuf.nibble(0), 16)
            else:
              db.vidFetch(16)
          branch =
            if n > 0:
              ExtBranchRef.init(psuffix.slice(0, n), startVid, 0)
            else:
              BranchRef.init(startVid, 0)

        block: # Copy the existing vertex and add it to the new branch
          let
            local = branch.setUsed(vtx.pfx[n], true)
            pfx = vtx.pfx.slice(n + 1)
            vtx = BranchRef(vtx)
          db.layersPutVtx(
            (root, local),
            if pfx.len > 0:
              ExtBranchRef.init(pfx, vtx.startVid, vtx.used)
            else:
              BranchRef.init(vtx.startVid, vtx.used),
          )

        let leafVtx = block: # add the new entry
          let local = branch.setUsed(psuffix[n], true)
          db.layersPutLeaf((root, local), psuffix.slice(n + 1), payload)

        db.layersPutVtx((root, cur), branch)

        resetKeys()
        return ok((leafVtx, nil, nil))

  err(MergeHikeFailed)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeAccountRecord*(
    db: AristoTxRef;                   # Database, top layer
    accPath: Hash32;          # Even nibbled byte path
    accRec: AristoAccount;             # Account data
      ): Result[bool,AristoError] =
  ## Merge the  key-value-pair argument `(accKey,accRec)` as an account
  ## ledger value, i.e. the the sub-tree starting at `STATE_ROOT_VID`.
  ##
  ## On success, the function returns `true` if the `accRec` argument was
  ## not on the database already or different from `accRec`, and `false`
  ## otherwise.
  ##
  discard db.mergePayloadImpl(STATE_ROOT_VID, accPath, Opt.none(AccLeafRef), accRec).valueOr:
    if error == MergeNoAction:
      return ok false
    return err(error)

  ok true

proc mergeStorageData*(
    db: AristoTxRef;                   # Database, top layer
    accPath: Hash32;                   # Needed for accounts payload
    stoPath: Hash32;                   # Storage data path (aka key)
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
    stoID = AccLeafRef(accHike.legs[^1].wp.vtx).stoID

    # Provide new storage ID when needed
    useID =
      if stoID.isValid: stoID                     # Use as is
      elif stoID.vid.isValid: (true, stoID.vid)   # Re-use previous vid
      else: (true, db.vidFetch())                 # Create new vid
    mixPath = mixUp(accPath, stoPath)
    # Call merge
    updated = db.mergePayloadImpl(
      useID.vid, stoPath, db.cachedStoLeaf(mixPath), stoData
    ).valueOr:
      if error == MergeNoAction:
        assert stoID.isValid         # debugging only
        return ok()

      return err(error)

  # Mark account path Merkle keys for update, except for the vtx we update below
  db.layersResKeys(accHike, skip = if not stoID.isValid: 1 else: 0)

  # Update leaf cache both of the merged value and potentially the displaced
  # leaf resulting from splitting a leaf into a branch with two leaves
  db.layersPutStoLeaf(mixPath, updated[0])

  if updated[1].isValid:
    let otherPath =
      Hash32(getBytes(NibblesBuf.fromBytes(stoPath.data).replaceSuffix(updated[1].pfx)))
    db.layersPutStoLeaf(mixUp(accPath, otherPath), updated[2])

  if not stoID.isValid:
    # Make sure that there is an account that refers to that storage trie
    let leaf = AccLeafRef(accHike.legs[^1].wp.vtx).dup # Dup on modify
    leaf.stoID = useID
    db.layersPutVtx((STATE_ROOT_VID, accHike.legs[^1].wp.vid), leaf)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
## Leaves are stored at vids derived from their path so that they can be
## fetched without traversing the trie, see `derivedVid()`. A branch stores
## the vid of each leaf child explicitly.

{.push raises: [].}

import
  std/typetraits,
  eth/common/hashes,
  results,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_layers, aristo_serialise, aristo_vid]

proc layersPutLeaf[T](
    db: AristoTxRef, rvid: RootedVertexID, path: NibblesBuf, payload: T
): auto =
  when T is UInt256:
    let vtx = StoLeafRef.init(path, payload)
  else:
    let vtx = AccLeafRef.init(path, payload, default(StorageID))

  db.layersPutVtx(rvid, vtx)
  vtx

proc escapeVid(db: AristoTxRef, root, derived: VertexID): VertexID =
  ## Allocate a vid for a leaf whose derived vid is shared with a sibling and
  ## make sure the derived vid holds a collision marker
  let existing = db.getVtxRc((root, derived))
  if existing.isErr or existing.value[0].vType != LeafPtr:
    db.layersPutVtx((root, derived), LeafPtrRef.init(VertexID(0)))
  db.vidFetch()

proc newBranch(
    db: AristoTxRef, root: VertexID, path: NibblesBuf, pos, n: int
): BranchRef =
  ## Create a branch whose extension prefix is `path[pos ..< pos + n]`
  let startVid =
    if root == STATE_ROOT_VID:
      db.accVidFetch(path.slice(0, pos + n) & NibblesBuf.nibble(0), 16)
    else:
      db.vidFetch(16)
  if n > 0:
    ExtBranchRef.init(path.slice(pos, pos + n), startVid, 0)
  else:
    BranchRef.init(startVid, 0)

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
  let derived = derivedVid(path)
  var
    path = NibblesBuf.fromBytes(path.data)
    pos = 0
    cur = root
    rootPtr = LeafPtrRef(nil)
    (vtx, _) = db.getVtxRc((root, cur)).valueOr:
      if error != GetVtxNotFound:
        return err(error)

      # We're at the root vertex and there is no data - this must be a fresh
      # VertexID!
      db.layersPutVtx((root, cur), LeafPtrRef.init(derived))
      return ok (db.layersPutLeaf((root, derived), path, payload), nil, nil)
    vids: ArrayBuf[NibblesBuf.high + 1, VertexID]
    vtxs: ArrayBuf[NibblesBuf.high + 1, BranchRef]

  if vtx.vType == LeafPtr:
    rootPtr = LeafPtrRef(vtx)
    if not rootPtr.vid.isValid:
      return err(MergeHikeFailed)
    cur = rootPtr.vid
    vtx = (?db.getVtxRc((root, cur)))[0]

  template resetKeys(skip: int) =
    # Reset cached hashes of touched verticies
    for i in (skip + 1)..vids.len:
      db.layersResKey((root, vids[^i]), vtxs[^i])

  template leafVidAt(childPos: int): VertexID =
    if childPos < DERIVED_VID_LEVEL:
      derived
    else:
      db.escapeVid(root, derived)

  while pos < path.len:
    var psuffix = path.slice(pos)
    let n = psuffix.sharedPrefixLen(vtx.pfx)
    case vtx.vType
    of Leaves:
      if n == vtx.pfx.len:
        # Same path - replace the current vertex with a new payload
        when payload is AristoAccount:
          if AccLeafRef(vtx).account == payload:
            return err(MergeNoAction)
          let leafVtx = db.layersUpdate((root, cur), AccLeafRef(vtx))
          leafVtx.account = payload
          leafVtx.stoID = AccLeafRef(vtx).stoID

        else:
          if StoLeafRef(vtx).stoData == payload:
            return err(MergeNoAction)
          let leafVtx = db.layersUpdate((root, cur), StoLeafRef(vtx))
          leafVtx.stoData = payload

        if not rootPtr.isNil:
          discard db.layersUpdate((root, root), rootPtr)

        resetKeys(0)
        return ok((leafVtx, nil, nil))

      # Turn leaf into a branch (or extension) then insert the two leaves
      # into the branch. The existing leaf keeps its vid unless it moves
      # below the derived vid level, the new branch takes the slot of the
      # existing leaf in the parent.
      let
        childPos = pos + n
        branch = db.newBranch(root, path, pos, n)
        brVid =
          if vids.len == 0:
            root
          else:
            let parent = db.layersUpdate((root, vids[^1]), vtxs[^1])
            parent.setBranch(path[pos - 1])
        otherVid =
          if cur == brVid or (childPos >= DERIVED_VID_LEVEL and cur.isDerived):
            db.vidFetch()
          else:
            cur

      let other = block: # Copy of existing leaf node, now one level deeper
        let pfx = vtx.pfx.slice(n + 1)
        when payload is AristoAccount:
          let accVtx = db.layersPutLeaf((root, otherVid), pfx, AccLeafRef(vtx).account)
          accVtx.stoID = AccLeafRef(vtx).stoID
          accVtx
        else:
          db.layersPutLeaf((root, otherVid), pfx, StoLeafRef(vtx).stoData)
      branch.setLeaf(vtx.pfx[n], otherVid)

      let newVid =
        if childPos < DERIVED_VID_LEVEL:
          derived
        else:
          db.layersPutVtx((root, derived), LeafPtrRef.init(VertexID(0)))
          db.vidFetch()
      let leafVtx = db.layersPutLeaf((root, newVid), psuffix.slice(n + 1), payload)
      branch.setLeaf(psuffix[n], newVid)

      db.layersPutVtx((root, brVid), branch)
      resetKeys(if vids.len == 0: 0 else: 1)

      # We need to return vtx here because its pfx member hasn't yet been
      # sliced off and is therefore shared with the hike
      return ok((leafVtx, vtx, other))

    of Branches:
      if vtx.pfx.len == n:
        # The existing branch is a prefix of the new entry
        let
          nibble = psuffix[vtx.pfx.len]
          next = BranchRef(vtx).bVid(nibble)

        if next.isValid:
          vids.add cur
          vtxs.add BranchRef(vtx)
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
          let
            brDup = db.layersUpdate((root, cur), BranchRef(vtx))
            newVid = leafVidAt(pos + n)
          brDup.setLeaf(nibble, newVid)
          let leafVtx = db.layersPutLeaf((root, newVid), psuffix.slice(n + 1), payload)

          resetKeys(0)
          return ok((leafVtx, nil, nil))
      else:
        # Partial path match - we need to split the existing branch at
        # the point of divergence, inserting a new branch
        let branch = db.newBranch(root, path, pos, n)

        block: # Copy the existing vertex and add it to the new branch
          let
            local = branch.setBranch(vtx.pfx[n])
            pfx = vtx.pfx.slice(n + 1)
            bvtx = BranchRef(vtx)
            moved =
              if pfx.len > 0:
                ExtBranchRef.init(pfx, bvtx.startVid, bvtx.used)
              else:
                BranchRef.init(bvtx.startVid, bvtx.used)
          moved.leafMask = bvtx.leafMask
          moved.leafVids = bvtx.leafVids
          db.layersPutVtx((root, local), moved)

        let
          newVid = leafVidAt(pos + n)
          leafVtx = db.layersPutLeaf((root, newVid), psuffix.slice(n + 1), payload)
        branch.setLeaf(psuffix[n], newVid)

        db.layersPutVtx((root, cur), branch)

        resetKeys(0)
        return ok((leafVtx, nil, nil))

    of BoundaryNode:
      let evtx = BoundaryNodeRef(vtx)
      if n == evtx.pfx.len:
        # Full prefix match: the new key would traverse into the absent branch
        # child. This is not supported in partial-trie / stateless mode.
        return err(MergeHikeFailed)
      else:
        # Partial prefix match: split the BoundaryNode at the divergence point,
        # creating a new branch. This is similar as for leaves except that
        # the existing BoundaryNode is moved down one level.
        let branch = db.newBranch(root, path, pos, n)

        # Place the existing BoundaryNode content at its new position
        let
          local = branch.setBranch(evtx.pfx[n])
          pfx = evtx.pfx.slice(n + 1)
        if pfx.len > 0:
          # Remaining prefix: create new BoundaryNode pointing to the same child.
          let newExt = BoundaryNodeRef.init(pfx, evtx.childKey)
          db.layersPutKey(
            (root, local), newExt,
            rlpEncodeExt(pfx, evtx.childKey).digestTo(HashKey))
        else:
          # No remaining prefix: store a nil as vertex with the known branch hash.
          # computeKeyImpl still works via kMap
          db.layersPutKey((root, local), BranchRef(nil), evtx.childKey)

        let
          newVid = leafVidAt(pos + n)
          leafVtx = db.layersPutLeaf((root, newVid), psuffix.slice(n + 1), payload)
        branch.setLeaf(psuffix[n], newVid)

        db.layersPutVtx((root, cur), branch)
        resetKeys(0)
        return ok((leafVtx, nil, nil))

    of LeafPtr:
      return err(MergeHikeFailed)

  err(MergeHikeFailed)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeAccount*(
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
  let updated = db.mergePayloadImpl(
    STATE_ROOT_VID, accPath, db.cachedAccLeaf(accPath), accRec
  ).valueOr:
    if error == MergeNoAction:
      return ok false
    return err(error)

  # Update leaf cache both of the merged value and potentially the displaced
  # leaf resulting from splitting a leaf into a branch with two leaves
  db.layersPutAccLeaf(accPath, updated[0])
  if updated[1].isValid:
    let otherPath =
      Hash32(getBytes(NibblesBuf.fromBytes(accPath.data).replaceSuffix(updated[1].pfx)))
    db.layersPutAccLeaf(otherPath, updated[2])

  ok true

proc mergeSlot*(
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
    accVtx = AccLeafRef(accHike.legs[^1].wp.vtx)
    stoID = accVtx.stoID

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

  # Mark account path Merkle keys for update - the leaf key is not stored so no
  # need to mark it
  db.layersResKeys(accHike, skip = 1)
  if accHike.legs.len == 1:
    db.resKeyRootLeaf(STATE_ROOT_VID)

  # Update leaf cache both of the merged value and potentially the displaced
  # leaf resulting from splitting a leaf into a branch with two leaves
  db.layersPutStoLeaf(mixPath, updated[0])

  if updated[1].isValid:
    let otherPath =
      Hash32(getBytes(NibblesBuf.fromBytes(stoPath.data).replaceSuffix(updated[1].pfx)))
    db.layersPutStoLeaf(mixUp(accPath, otherPath), updated[2])

  if not stoID.isValid:
    # Make sure that there is an account that refers to that storage trie
    let leaf = db.layersUpdate((STATE_ROOT_VID, accHike.legs[^1].wp.vid), accVtx) # Dup on modify
    leaf.stoID = useID
    db.layersPutAccLeaf(accPath, leaf)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

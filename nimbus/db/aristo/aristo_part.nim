# nimbus-eth1
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Add single vertices and maintain partiel tries
## ===========================================================
##
{.push raises: [].}

import
  std/[sets, sequtils],
  eth/common,
  results,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_merge, aristo_layers,
       aristo_utils],
  #./aristo_part/part_debug,
  ./aristo_part/[part_chain_rlp, part_ctx, part_desc, part_helpers]

export
  PartStateCtx,
  PartStateMode,
  PartStateRef,
  init

# ------------------------------------------------------------------------------
# Public constructor and other admin functions
# ------------------------------------------------------------------------------

proc roots*(ps: PartStateRef): seq[VertexID] =
  ## Getter: list of root vertex IDs from `ps`.
  ps.core.keys.toSeq

iterator perimeter*(
    ps: PartStateRef;
    root: VertexID;
      ): (RootedVertexID, HashKey) =
  ## Retrieve the list of dangling vertex IDs relative to `ps`.
  ps.core.withValue(root,keys):
    for (key,rvid) in ps.byKey.pairs:
      if rvid.root == root and key notin keys[] and key notin ps.changed:
        yield (rvid,key)

iterator updated*(
    ps: PartStateRef;
    root: VertexID;
      ): (RootedVertexID, HashKey) =
  ## Retrieve the list of changed vertex IDs relative to `ps`. These vertices
  ## IDs are not considered on the perimeter, anymore.
  for key in ps.changed:
    let rvid = ps[key]
    if rvid.root == root:
      yield (rvid,key)

iterator vkPairs*(ps: PartStateRef): (RootedVertexID, HashKey) =
  ## Retrieve the list of cached `(key,vertex-ID)` pairs.
  for (key, rvid) in ps.byKey.pairs:
    yield (rvid, key)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc partGenericTwig*(
    db: AristoDbRef;
    root: VertexID;
    path: NibblesBuf;
      ): Result[seq[Blob], AristoError] =
  ## This function returns a chain of rlp-encoded nodes along the argument
  ## path `(root,path)`.
  ##
  var chain: seq[Blob]
  ? db.chainRlpNodes((root,root), path, chain)
  ok chain

proc partGenericTwig*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[seq[Blob], AristoError] =
  ## Variant of `partGenericTwig()`.
  ##
  ## Note: This function provides a functionality comparable to the
  ## `getBranch()` function from `hexary.nim`
  ##
  db.partGenericTwig(root, NibblesBuf.fromBytes path)

proc partAccountTwig*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[seq[Blob], AristoError] =
  ## Variant of `partGetBranch()`.
  db.partGenericTwig(VertexID(1), NibblesBuf.fromBytes accPath.data)

proc partStorageTwig*(
    db: AristoDbRef;
    accPath: Hash256;
    stoPath: Hash256;
      ): Result[seq[Blob], AristoError] =
  ## Variant of `partGetBranch()`.
  let vid = ? db.fetchStorageID accPath
  db.partGenericTwig(vid, NibblesBuf.fromBytes stoPath.data)

# ----------------

proc partPut*(
    ps: PartStateRef;                         # Partial database descriptor
    proof: openArray[Blob];                   # RLP encoded proof nodes
    mode = AutomaticPayload;                  # Try accounts, otherwise generic
      ): Result[void,AristoError] =
  ## Decode an argument list `proof` of RLP encoded nodes and add them to
  ## a partial `Patricia` tree. The `Merkle` keys will all be cached in the
  ## state descriptor `ps`.
  ##
  let
    nodes = ? proof.toNodesTab(mode)
    bl = nodes.backLinks()

  # Check wether the chain has an accounts leaf node
  ? ps.updateAccountsTree(nodes, bl, mode)

  when false: # or true:
    echo ">>> partPut",
      "\n    chains\n    ", bl.chains.pp(ps),
      ""

  # Assign vertex IDs. If possible, use IDs from `state` lookup
  var seen: HashSet[HashKey]
  for chain in bl.chains:

    # Calculate root vertex ID
    let root = ? ps.getTreeRootVid chain[^1]

    for n,key in chain:
      var
        rvid: RootedVertexID
        (stopHere, vidFromStateDb) = (false,false) # not both `true`

      # Parent might have been part of an earlier chain, already
      if n < chain.len - 1:
        let parKey = chain[n+1]
        if parKey in seen:
          block findLink:
            let parent = nodes.getOrDefault parKey
            for (subVid,subKey) in parent.subVidKeys:
              if subKey == key:
                rvid = (root,subVid)
                stopHere = true
                break findLink
            # In theory, the following clause cannot happen
            return err(PartMissingUplinkInternalError)

      let node = nodes.getOrDefault key

      # Get vertex ID and set a flag whether it was seen on state lookup
      if not rvid.isValid:
        (rvid, vidFromStateDb) = ? ps.getRvid(root, key)

      # Use from partial state database if possible
      if vidFromStateDb and not ps.isCore(key):
        let vtx = ps.db.getVtx rvid
        if vtx.isValid:
          # Register core node.  Even though these nodes are only local to this
          # loop local, they need to be updated because another `chain` might
          # merge into this one at exactly this node.
          case node.vType:
          of Leaf:
            node.lData = vtx.lData
          of Branch:
            node.bVid = vtx.bVid
          ps.addCore(root, key)                # register core node
          ps.pureExt.del key                   # core node can't be an extension
          continue

      # Handle raw extension (there should not be many.) These records are
      # stored separately off the database and will only be temporarily
      # inserted into the database on demand.
      if node.prfType == isExtension:
        ps.pureExt[key] = PrfExtension(xPfx: node.ePfx, xLink: node.key[0])
        continue

      # Otherwise assign new VIDs to a core node. Even though these nodes are
      # only local to this loop local, they need to be updated because another
      # `chain` might merge into this one at exactly this node.
      case node.vType:
      of Leaf:
        let lKey = node.key[0]
        if node.lData.pType == AccountData and lKey.isValid:
          node.lData.stoID = (? ps.getRvid(root, lKey))[0].vid
      of Branch:
        for n in 0 .. 15:
          let bKey = node.key[n]
          if bKey.isValid:
            node.bVid[n] = (? ps.getRvid(root, bKey))[0].vid
      ps.addCore(root, key)                    # register core node
      ps.pureExt.del key                       # core node can't be an extension

      # Store vertex on database
      ps.db.layersPutVtx(rvid, VertexRef(node))
      seen.incl key                            # node was processed here
      if stopHere:                             # follow up tail of earlier chain
        #discard ps.pp()
        #echo ">>> partPut (2) stop at ", key.pp(ps.db)
        break

  when false: # or true:
    for (rvid,key) in ps.vkPairs:
      ps.db.top.kMap[rvid] = key
    echo ">>> partPut (8)",
      "\n    ps\n    ", ps.pp(), # byKeyOk=false),
      "\n    chains\n    ", bl.chains.pp(ps),
      "\n    perimeter\n    ", ps.perimeter(VertexID 2).toSeq.sorted.pp,
      ""
    for (rvid,_) in ps.vkPairs:
      ps.db.top.kMap.del rvid
  ok()


proc partGetSubTree*(ps: PartStateRef; rootHash: Hash256): VertexID =
  ## For the argument `roothash` retrieve the root vertex ID of a particular
  ## sub tree from the partial state descriptor argument `ps`. The function
  ## returns `VertexID(0)` if there is no match.
  ##
  for vid in ps.core.keys:
    if ps[vid].to(Hash256) == rootHash:
      return vid


proc partReRoot*(
    ps: PartStateRef;
    frRoot: VertexID;
    toRoot: VertexID;
      ): Result[void,AristoError] =
  ## Realign a generic root vertex (i.e `$2`..`$(LEAST_FREE_VID-1)`) for a
  ## `proof` state to a new root vertex.
  if frRoot == toRoot:
    return ok() # nothing to do

  if frRoot notin ps.core:
    return err(PartArgNotInCore)
  if frRoot < VertexID(2) or LEAST_FREE_VID <= frRoot.ord or
     toRoot < VertexID(2) or LEAST_FREE_VID <= toRoot.ord:
    return err(PartArgNotGenericRoot)
  # Verify that the tree slot is free
  if toRoot in ps.core:
    return err(PartArgRootAlreadyUsed)
  if ps.db.getVtx((toRoot,toRoot)).isValid:
    return err(PartArgRootAlreadyOnDatabase)

  # Migrate
  for key in ps.byKey.keys:
    let frRvid = ps[key]

    if frRvid.root != frRoot:
      continue

    let toRvid = if frRvid.vid == frRoot: (toRoot,toRoot)
                 else: (toRoot,frRvid.vid)

    # Update lookup table
    ps[key] = toRvid

    # Get vertex from database (if any)
    var vtx = ps.db.getVtx frRvid
    if ps.isCore(key):
      if not vtx.isValid:
        return err(PartChkCoreVtxMissing)
    elif key in ps.changed:
      if not vtx.isValid:
        return err(PartChkChangedVtxMissing)
    else:
      if vtx.isValid:
        return err(PartChkPerimeterVtxMustNotExist)
      continue

    # Move vertex on database
    ps.db.layersResVtx(frRvid)
    ps.db.layersPutVtx(toRvid, vtx)

    # Update links
    for childVid in vtx.subVids:
      ps[ps[childVid]] = (toRoot,childVid)

  #echo ">>> putReRoot (9)",
  #  "\n    ps\n    ", ps.pp(byKeyOk=false),
  #  "\n    ==========",
  #  ""
  ok()

# ------------------------------------------------------------------------------
# Public merge functions on partial tree database
# ------------------------------------------------------------------------------

proc partMergeGenericData*(
    ps: PartStateRef;
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
      ): Result[bool,AristoError] =
  ## ..
  let mergeError = block:
    # Opportunistically try whether it just works
    let rc = ps.db.mergeGenericData(root, path, data)
    if rc.isOk or rc.error != GetVtxNotFound:
      return rc
    rc.error

  # Otherwise clean the way removing blind link and retry
  let
    ctx = ps.ctxMergeBegin(root, path).valueOr:
      let ctxErr = if error == PartCtxNotAvailable: mergeError else: error
      return err(ctxErr)
    rc = ps.db.mergeGenericData(root, path, data)

  # Evaluate result => commit/rollback
  if rc.isErr:
    ? ctx.ctxMergeRollback()
    return rc
  if not ? ctx.ctxMergeCommit():
    return err(PartVtxSlotWasNotModified)

  ok(rc.value)


proc partMergeAccountRecord*(
    ps: PartStateRef;
    accPath: Hash256;                  # Even nibbled byte path
    accRec: AristoAccount;             # Account data
      ): Result[bool,AristoError] =
  ## ..
  let mergeError = block:
    # Opportunistically try whether it just works
    let rc = ps.db.mergeAccountRecord(accPath, accRec)
    if rc.isOk or rc.error != GetVtxNotFound:
      return rc
    rc.error

  # Otherwise clean the way removing blind link and retry
  let
    ctx = ps.ctxMergeBegin(accPath).valueOr:
      let ctxErr = if error == PartCtxNotAvailable: mergeError else: error
      return err(ctxErr)
    rc = ps.db.mergeAccountRecord(accPath, accRec)

  # Evaluate result => commit/rollback
  if rc.isErr:
    ? ctx.ctxMergeRollback()
    return rc
  if not ? ctx.ctxMergeCommit():
    return err(PartVtxSlotWasNotModified)

  ok(rc.value)


proc mergeStorageData*(
    ps: PartStateRef;
    accPath: Hash256;                  # Needed for accounts payload
    stoPath: Hash256;                  # Storage data path (aka key)
    stoData: UInt256;                  # Storage data payload value
      ): Result[void,AristoError] =
  block:
    # Opportunistically try whether it just works
    let rc = ps.db.mergeStorageData(accPath, stoPath, stoData)
    if rc.isOk or rc.error != GetVtxNotFound:
      return rc

  raiseAssert "TODO: mergeStorageData() is not fully functional yet"

# ------------------------------------------------------------------------------
# Public proof functions on partial tree database
# ------------------------------------------------------------------------------

proc partWithExtBegin*(ps: PartStateRef): Result[void,AristoError] =
  var rollback: seq[RootedVertexID]
  proc restore() =
    for rv in rollback:
      ps.db.layersResVtx(rv)

  for (key,ext) in ps.pureExt.pairs:
    let rvid = ps[key]
    if ps.db.getKey(rvid).isValid:
      restore()
      return err(PartExtVtxExistsAlready)
    ps.db.layersPutVtx(rvid, VertexRef(vType: Branch, ePfx: ext.xPfx))
    rollback.add rvid
  ok()

proc partWithExtEnd*(ps: PartStateRef): Result[void,AristoError] =
  var rollback: seq[(RootedVertexID,PrfExtension)]
  proc restore() =
    for (rvid,ext) in rollback:
      ps.db.layersPutVtx(rvid, VertexRef(vType: Branch, ePfx: ext.xPfx))

  for (key,ext) in ps.pureExt.pairs:
    let rvid = ps[key]
    # Check vertex whether it has changed
    let vtx = ps.db.getVtx(rvid)
    if not vtx.isValid:
      restore()
      return err(PartExtVtxHasVanished)
    if vtx.vType != Branch or
       vtx.ePfx != ext.xPfx or
       vtx.bVid != array[16,VertexID].default:
      restore()
      return err(PartExtVtxWasModified)
    rollback.add (rvid,ext)
    ps.db.layersResVtx(rvid)
  ok()

template partWithExtensions*(ps: PartStateRef; code: untyped): untyped =
  const info = "partWithExtensions"
  block:
    let rc = ps.partWithExtBegin()
    if rc.isErr:
      raiseAssert: info & ": " & $rc.error
  defer:
    let rc = ps.partWithExtEnd()
    if rc.isErr:
      raiseAssert: info & ": " & $rc.error
  code

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

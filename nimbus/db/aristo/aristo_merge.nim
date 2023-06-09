# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
## This module merges `NodeTag` values as hexary lookup paths into the
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
  std/[sequtils, sets, tables],
  chronicles,
  eth/[common, trie/nibbles],
  stew/results,
  ../../sync/protocol,
  "."/[aristo_constants, aristo_desc, aristo_error, aristo_get, aristo_hike,
       aristo_path, aristo_transcode, aristo_vid]

logScope:
  topics = "aristo-merge"

type
  LeafSubKVP* = object
    ## Generalised key-value pair for a sub-trie. The main trie is the
    ## sub-trie with `root=VertexID(1)`.
    leafKey*: LeafKey                  ## Full `Patricia Trie` path root-to-leaf
    payload*: PayloadRef               ## Leaf data payload

  LeafMainKVP* = object
    ## Variant of `LeafSubKVP` for the main trie, implies: `root=VertexID(1)`
    pathTag*: NodeTag                  ## Path root-to-leaf in main trie
    payload*: PayloadRef               ## Leaf data payload

# ------------------------------------------------------------------------------
# Private getters & setters
# ------------------------------------------------------------------------------

proc xPfx(vtx: VertexRef): NibblesSeq =
  case vtx.vType:
  of Leaf:
    return vtx.lPfx
  of Extension:
    return vtx.ePfx
  of Branch:
    doAssert vtx.vType != Branch # Ooops

proc `xPfx=`(vtx: VertexRef, val: NibblesSeq) =
  case vtx.vType:
  of Leaf:
    vtx.lPfx = val
  of Extension:
    vtx.ePfx = val
  of Branch:
    doAssert vtx.vType != Branch # Ooops

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc clearMerkleKeys(
    db: AristoDb;                      # Database, top layer
    hike: Hike;                        # Implied vertex IDs to clear hashes for
    vid: VertexID;                     # Additionall vertex IDs to clear
      ) =
  for vid in hike.legs.mapIt(it.wp.vid) & @[vid]:
    let key = db.top.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
    if key != EMPTY_ROOT_KEY:
      db.top.kMap.del vid
      db.top.pAmk.del key
    elif db.getKeyBackend(vid).isOK:
      # Register for deleting on backend
      db.top.dKey.incl vid

# -----------

proc insertBranch(
    db: AristoDb;                      # Database, top layer
    hike: Hike;                        # Current state
    linkID: VertexID;                  # Vertex ID to insert
    linkVtx: VertexRef;                # Vertex to insert
    payload: PayloadRef;               # Leaf data payload
     ): Hike =
  ##
  ## Insert `Extension->Branch` vertex chain or just a `Branch` vertex
  ##
  ##   ... --(linkID)--> <linkVtx>
  ##
  ##   <-- immutable --> <---- mutable ----> ..
  ##
  ## will become either
  ##
  ##   --(linkID)-->
  ##        <extVtx>             --(local1)-->
  ##          <forkVtx>[linkInx] --(local2)--> <linkVtx*>
  ##                   [leafInx] --(local3)--> <leafVtx>
  ##
  ## or in case that there is no common prefix
  ##
  ##   --(linkID)-->
  ##          <forkVtx>[linkInx] --(local2)--> <linkVtx*>
  ##                   [leafInx] --(local3)--> <leafVtx>
  ##
  ## *) vertex was slightly modified or removed if obsolete `Extension`
  ##
  let n = linkVtx.xPfx.sharedPrefixLen hike.tail

  # Verify minimum requirements
  if hike.tail.len == n:
    # Should have been tackeld by `hikeUp()`, already
    return Hike(error: MergeLeafGarbledHike)
  if linkVtx.xPfx.len == n:
    return Hike(error: MergeBrLinkVtxPfxTooShort)

  # Provide and install `forkVtx`
  let
    forkVtx = VertexRef(vType: Branch)
    linkInx = linkVtx.xPfx[n]
    leafInx = hike.tail[n]
  var
    leafLeg = Leg(nibble: -1)

  # Install `forkVtx`
  block:
    # Clear Merkle hashes (aka node keys) unless proof mode.
    if db.top.pPrf.len == 0:
      db.clearMerkleKeys(hike, linkID)
    elif linkID in db.top.pPrf:
      return Hike(error: MergeNonBranchProofModeLock)

    if linkVtx.vType == Leaf:
      # Update vertex path lookup
      let
        path = hike.legsTo(NibblesSeq) & linkVtx.lPfx
        rc = path.pathToTag()
      if rc.isErr:
        debug "Branch link leaf path garbled", linkID, path
        return Hike(error: MergeBrLinkLeafGarbled)

      let
        local = db.vidFetch
        lky = LeafKey(root: hike.root, path: rc.value)
      db.top.lTab[lky] = local         # update leaf path lookup cache
      db.top.sTab[local] = linkVtx
      linkVtx.lPfx = linkVtx.lPfx.slice(1+n)
      forkVtx.bVid[linkInx] = local

    elif linkVtx.ePfx.len == n + 1:
      # This extension `linkVtx` becomes obsolete
      forkVtx.bVid[linkInx] = linkVtx.eVid

    else:
      let local = db.vidFetch
      db.top.sTab[local] = linkVtx
      linkVtx.ePfx = linkVtx.ePfx.slice(1+n)
      forkVtx.bVid[linkInx] = local

  block:
    let local = db.vidFetch
    forkVtx.bVid[leafInx] = local
    leafLeg.wp.vid = local
    leafLeg.wp.vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail.slice(1+n),
      lData: payload)
    db.top.sTab[local] = leafLeg.wp.vtx

  # Update branch leg, ready to append more legs
  result = Hike(root: hike.root, legs: hike.legs)

  # Update in-beween glue linking `branch --[..]--> forkVtx`
  if 0 < n:
    let extVtx = VertexRef(
      vType: Extension,
      ePfx:  hike.tail.slice(0,n),
      eVid:  db.vidFetch)

    db.top.sTab[linkID] = extVtx

    result.legs.add Leg(
      nibble: -1,
      wp:     VidVtxPair(
        vid: linkID,
        vtx: extVtx))

    db.top.sTab[extVtx.eVid] = forkVtx
    result.legs.add Leg(
      nibble: leafInx.int8,
      wp:     VidVtxPair(
        vid: extVtx.eVid,
        vtx: forkVtx))
  else:
    db.top.sTab[linkID] = forkVtx
    result.legs.add Leg(
      nibble: leafInx.int8,
      wp:     VidVtxPair(
        vid: linkID,
        vtx: forkVtx))

  result.legs.add leafLeg


proc concatBranchAndLeaf(
    db: AristoDb;                      # Database, top layer
    hike: Hike;                        # Path top has a `Branch` vertex
    brVid: VertexID;                   # Branch vertex ID from from `Hike` top
    brVtx: VertexRef;                  # Branch vertex, linked to from `Hike`
    payload: PayloadRef;               # Leaf data payload
      ): Hike =
  ## Append argument branch vertex passed as argument `(brID,brVtx)` and then
  ## a `Leaf` vertex derived from the argument `payload`.
  ##
  if hike.tail.len == 0:
    return Hike(error: MergeBranchGarbledTail)

  let nibble = hike.tail[0].int8
  if brVtx.bVid[nibble] != VertexID(0):
    return Hike(error: MergeRootBranchLinkBusy)

  # Clear Merkle hashes (aka node keys) unless proof mode.
  if db.top.pPrf.len == 0:
    db.clearMerkleKeys(hike, brVid)
  elif brVid in db.top.pPrf:
    return Hike(error: MergeBranchProofModeLock) # Ooops

  # Append branch node
  result = Hike(root: hike.root, legs: hike.legs)
  result.legs.add Leg(wp: VidVtxPair(vtx: brVtx, vid: brVid), nibble: nibble)

  # Append leaf node
  let
    vid = db.vidFetch
    vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail.slice(1),
      lData: payload)
  brVtx.bVid[nibble] = vid
  db.top.sTab[vid] = vtx
  result.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc topIsBranchAddLeaf(
    db: AristoDb;                      # Database, top layer
    hike: Hike;                        # Path top has a `Branch` vertex
    payload: PayloadRef;               # Leaf data payload
      ): Hike =
  ## Append a `Leaf` vertex derived from the argument `payload` after the top
  ## leg of the `hike` argument which is assumend to refert to a `Branch`
  ## vertex. If successful, the function returns the updated `hike` trail.
  if hike.tail.len == 0:
    return Hike(error: MergeBranchGarbledTail)

  let nibble = hike.legs[^1].nibble
  if nibble < 0:
    return Hike(error: MergeBranchGarbledNibble)

  let
    branch = hike.legs[^1].wp.vtx
    linkID = branch.bVid[nibble]
    linkVtx = db.getVtx linkID

  if linkVtx.isNil:
    #
    #  .. <branch>[nibble] --(linkID)--> nil
    #
    #  <-------- immutable ------------> <---- mutable ----> ..
    #
    if db.top.pPrf.len == 0:
      # Not much else that can be done here
      debug "Dangling leaf link, reused", branch=hike.legs[^1].wp.vid,
        nibble, linkID, leafPfx=hike.tail

    # Reuse placeholder entry in table
    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail,
      lData: payload)
    db.top.sTab[linkID] = vtx
    result = Hike(root: hike.root, legs: hike.legs)
    result.legs.add Leg(wp: VidVtxPair(vid: linkID, vtx: vtx), nibble: -1)
    return

  if linkVtx.vType == Branch:
    # Slot link to a branch vertex should be handled by `hikeUp()`
    #
    #  .. <branch>[nibble] --(linkID)--> <linkVtx>[]
    #
    #  <-------- immutable ------------> <---- mutable ----> ..
    #
    return db.concatBranchAndLeaf(hike, linkID, linkVtx, payload)

  db.insertBranch(hike, linkID, linkVtx, payload)


proc topIsExtAddLeaf(
    db: AristoDb;                      # Database, top layer
    hike: Hike;                        # Path top has an `Extension` vertex
    payload: PayloadRef;               # Leaf data payload
      ): Hike =
  ## Append a `Leaf` vertex derived from the argument `payload` after the top
  ## leg of the `hike` argument which is assumend to refert to a `Extension`
  ## vertex. If successful, the function returns the
  ## updated `hike` trail.
  let
    extVtx = hike.legs[^1].wp.vtx
    extVid = hike.legs[^1].wp.vid
    brVid = extVtx.eVid
    brVtx = db.getVtx brVid

  result = Hike(root: hike.root, legs: hike.legs)

  if brVtx.isNil:
    # Blind vertex, promote to leaf node.
    #
    #  --(extVid)--> <extVtx> --(brVid)--> nil
    #
    #  <-------- immutable -------------->
    #
    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  extVtx.ePfx & hike.tail,
      lData: payload)
    db.top.sTab[extVid] = vtx
    result.legs[^1].wp.vtx = vtx

  elif brVtx.vType != Branch:
    return Hike(error: MergeBranchRootExpected)

  else:
    let
      nibble = hike.tail[0].int8
      linkID = brVtx.bVid[nibble]
    #
    # Required
    #
    #  --(extVid)--> <extVtx> --(brVid)--> <brVtx>[nibble] --(linkID)--> nil
    #
    #  <-------- immutable --------------> <-------- mutable ----------> ..
    #
    if linkID != VertexID(0):
      return Hike(error: MergeRootBranchLinkBusy)

    # Clear Merkle hashes (aka node keys) unless proof mode
    if db.top.pPrf.len == 0:
      db.clearMerkleKeys(hike, brVid)
    elif brVid in db.top.pPrf:
      return Hike(error: MergeBranchProofModeLock)

    let
      vid = db.vidFetch
      vtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    brVtx.bVid[nibble] = vid
    db.top.sTab[vid] = vtx
    result.legs[^1].nibble = nibble
    result.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)


proc topIsEmptyAddLeaf(
    db: AristoDb;                      # Database, top layer
    hike: Hike;                        # No path legs
    rootVtx: VertexRef;                # Root vertex
    payload: PayloadRef;               # Leaf data payload
     ): Hike =
  ## Append a `Leaf` vertex derived from the argument `payload` after the
  ## argument vertex `rootVtx` and append both the empty arguent `hike`.
  if rootVtx.vType == Branch:

    let nibble = hike.tail[0].int8
    if rootVtx.bVid[nibble] != VertexID(0):
      return Hike(error: MergeRootBranchLinkBusy)

    # Clear Merkle hashes (aka node keys) unless proof mode
    if db.top.pPrf.len == 0:
      db.clearMerkleKeys(hike, hike.root)
    elif hike.root in db.top.pPrf:
      return Hike(error: MergeBranchProofModeLock)

    let
      leafVid = db.vidFetch
      leafVtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    rootVtx.bVid[nibble] = leafVid
    db.top.sTab[leafVid] = leafVtx
    return Hike(
      root: hike.root,
      legs: @[Leg(wp: VidVtxPair(vtx: rootVtx, vid: hike.root), nibble: nibble),
              Leg(wp: VidVtxPair(vtx: leafVtx, vid: leafVid), nibble: -1)])

  db.insertBranch(hike, hike.root, rootVtx, payload)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(
    db: AristoDb;                      # Database, top layer
    leaf: LeafSubKVP;                  # Leaf item to add to the database
      ): Hike =
  ## Merge the argument `leaf` key-value-pair into the top level vertex table
  ## of the database `db`. The field `pathKey` of the `leaf` argument is used
  ## to index the leaf vertex on the `Patricia Trie`. The field `payload` is
  ## stored with the leaf vertex in the database unless the leaf vertex exists
  ## already.
  ##
  if db.top.lTab.hasKey leaf.leafKey:
    result.error = MergeLeafPathCachedAlready

  else:
    let hike = leaf.leafKey.hikeUp(db)

    if 0 < hike.legs.len:
      case hike.legs[^1].wp.vtx.vType:
      of Branch:
        result = db.topIsBranchAddLeaf(hike, leaf.payload)
      of Leaf:
        if 0 < hike.tail.len:          # `Leaf` vertex problem?
          return Hike(error: MergeLeafGarbledHike)
        result = hike
      of Extension:
        result = db.topIsExtAddLeaf(hike, leaf.payload)

    else:
      # Empty hike
      let rootVtx = db.getVtx hike.root

      if not rootVtx.isNil:
        result = db.topIsEmptyAddLeaf(hike,rootVtx,leaf.payload)
      else:
        # Bootstrap for existing root ID
        let wp = VidVtxPair(
          vid: hike.root,
          vtx: VertexRef(
            vType: Leaf,
            lPfx:  leaf.leafKey.path.pathAsNibbles,
            lData: leaf.payload))
        db.top.sTab[wp.vid] = wp.vtx
        result = Hike(root: wp.vid, legs: @[Leg(wp: wp, nibble: -1)])

    # Update leaf acccess cache
    if result.error == AristoError(0):
      db.top.lTab[leaf.leafKey] = result.legs[^1].wp.vid

    # End else (1st level)

proc merge*(
    db: AristoDb;                      # Database, top layer
    leafs: openArray[LeafSubKVP];      # Leaf items to add to the database
      ): tuple[merged: int, dups: int, error: AristoError] =
  ## Variant of `merge()` for leaf lists.
  var (merged, dups) = (0, 0)
  for n,w in leafs:
    let hike = db.merge(w)
    if hike.error == AristoError(0):
      merged.inc
    elif hike.error == MergeLeafPathCachedAlready:
      dups.inc
    else:
      return (n,dups,hike.error)

  (merged, dups, AristoError(0))

proc merge*(
    db: AristoDb;                      # Database, top layer
    leafs: openArray[LeafMainKVP];     # Leaf items to add to the database
      ): tuple[merged: int, dups: int, error: AristoError] =
  ## Variant of `merge()` for leaf lists on the main trie
  var (merged, dups) = (0, 0)
  for n,w in leafs:
    let hike = db.merge(LeafSubKVP(
      leafKey: LeafKey(root: VertexID(1), path: w.pathTag),
      payload: w.payload))
    if hike.error == AristoError(0):
      merged.inc
    elif hike.error == MergeLeafPathCachedAlready:
      dups.inc
    else:
      return (n,dups,hike.error)

  (merged, dups, AristoError(0))

# ---------------------

proc merge*(
    db: AristoDb;                      # Database, top layer
    nodeKey: NodeKey;                  # Merkel hash of node
    node: NodeRef;                     # Node derived from RLP representation
      ): Result[VertexID,AristoError]  =
  ## The function merges a node key `nodeKey` expanded from its RLP
  ## representation into the `Aristo Trie` database. The vertex is split off
  ## from the node and stored separately. So are the Merkle hashes. The
  ## vertex is labelled `locked`.
  ##
  ## The `node` argument is *not* checked, whether the vertex IDs have been
  ## allocated, already. If the node comes straight from the `decode()` RLP
  ## decoder as expected, these vertex IDs will be all zero.
  ##
  proc register(key: NodeKey): VertexID =
    var vid = db.top.pAmk.getOrDefault(key, VertexID(0))
    if vid == VertexID(0):
      vid = db.vidAttach key
    vid

  # Check whether the record is correct
  if node.error != AristoError(0):
    return err(node.error)

  # Verify `nodeKey`
  if nodeKey == EMPTY_ROOT_KEY:
    return err(MergeNodeKeyEmpty)

  # Check whether the node exists, already. If not then create a new vertex ID
  var vid = db.top.pAmk.getOrDefault(nodeKey, VertexID(0))
  if vid == VertexID(0):
    vid = nodeKey.register
  else:
    let key = db.top.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
    if key == nodeKey:
      if db.top.sTab.hasKey vid:
        # This is tyically considered OK
        return err(MergeNodeKeyCachedAlready)
      # Otherwise proceed
    elif key != EMPTY_ROOT_KEY:
      # Different key assigned => error
      return err(MergeNodeKeyDiffersFromCached)

  let vtx = node.to(VertexRef) # the vertex IDs need to be set up now (if any)

  case node.vType:
  of Leaf:
    discard
  of Extension:
    if node.key[0] != EMPTY_ROOT_KEY:
      let eVid = db.top.pAmk.getOrDefault(node.key[0], VertexID(0))
      if eVid != VertexID(0):
        vtx.eVid = eVid
      else:
        vtx.eVid = node.key[0].register
  of Branch:
    for n in 0..15:
      if node.key[n] != EMPTY_ROOT_KEY:
        let bVid = db.top.pAmk.getOrDefault(node.key[n], VertexID(0))
        if bVid != VertexID(0):
          vtx.bVid[n] = bVid
        else:
          vtx.bVid[n] = node.key[n].register

  db.top.pPrf.incl vid
  db.top.sTab[vid] = vtx
  ok vid

proc merge*(
    db: AristoDb;                      # Database, top layer
    proof: openArray[SnapProof];       # RLP encoded node records
      ): tuple[merged: int, dups: int, error: AristoError]
      {.gcsafe, raises: [RlpError].} =
  ## The function merges the argument `proof` list of RLP encoded node records
  ## into the `Aristo Trie` database. This function is intended to be used with
  ## the proof nodes as returened by `snap/1` messages.
  var (merged, dups) = (0, 0)
  for n,w in proof:
    let
      key = w.Blob.digestTo(NodeKey)
      node = w.Blob.decode(NodeRef)
      rc = db.merge(key, node)
    if rc.isOK:
      merged.inc
    elif rc.error == MergeNodeKeyCachedAlready:
      dups.inc
    else:
      return (n, dups, rc.error)

  (merged, dups, AristoError(0))

proc merge*(
    db: AristoDb;                      # Database, top layer
    rootKey: NodeKey;                  # Merkle hash for root
    rootVid = VertexID(0)              # Optionally, force root vertex ID
      ): Result[VertexID,AristoError] =
  ## Set up a `rootKey` associated with a vertex ID.
  ##
  ## If argument `rootVid` is unset (defaults to `VertexID(0)`) then the main
  ## trie is tested for `VertexID(1)`. If assigned with a different Merkle key
  ## already, a new vertex ID is created and the argument root key is assigned
  ## to this vertex ID.
  ##
  ## If the argument `rootVid` is set (to a value different from `VertexID(0)`),
  ## then a sub-trie with root `rootVid` is checked for. If it exists with a
  ## diffent root key assigned, then an error is returned. Otherwise a new
  ## vertex ID is created and the argument root key is assigned.
  ##
  ## Upon successful return, the vertex ID assigned to the root key is returned.
  ##
  if rootKey == EMPTY_ROOT_KEY:
    return err(MergeRootKeyEmpty)

  if rootVid == VertexID(0) or
     rootVid == VertexID(1):
    let key = db.getKey VertexID(1)
    if key == rootKey:
      return ok VertexID(1)

    # Otherwise assign if empty
    if key == EMPTY_ROOT_KEY:
      db.vidAttach(rootKey, VertexID(1))
      return ok VertexID(1)

    # Create new root key
    if rootVid == VertexID(0):
      return ok db.vidAttach(rootKey)

  else:
    let key = db.getKey rootVid
    if key == rootKey:
      return ok rootVid

    if key == EMPTY_ROOT_KEY:
      db.vidAttach(rootKey, rootVid)
      return ok rootVid

  err(MergeRootKeyDiffersForVid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

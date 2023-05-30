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
  LeafKVP* = object
    ## Generalised key-value pair
    pathTag*: NodeTag                  ## `Patricia Trie` path root-to-leaf
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


proc clearMerkleKeys(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Implied vertex IDs to clear hashes for
    vid: VertexID;                     # Additionall vertex IDs to clear
      ) =
  for vid in hike.legs.mapIt(it.wp.vid) & @[vid]:
    let key = db.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
    if key != EMPTY_ROOT_KEY:
      db.kMap.del vid
      db.pAmk.del key

# -----------

proc insertBranch(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;
    linkID: VertexID;
    linkVtx: VertexRef;
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
    if db.pPrf.len == 0:
      db.clearMerkleKeys(hike, linkID)
    elif linkID in db.pPrf:
      return Hike(error: MergeNonBranchProofModeLock)

    if linkVtx.vType == Leaf:
      # Update vertex path lookup
      let
        path = hike.legsTo(NibblesSeq) & linkVtx.lPfx
        rc = path.pathToTag()
      if rc.isErr:
        debug "Branch link leaf path garbled", linkID, path
        return Hike(error: MergeBrLinkLeafGarbled)

      let local = db.vidFetch
      db.lTab[rc.value] = local        # update leaf path lookup cache
      db.sTab[local] = linkVtx
      linkVtx.lPfx = linkVtx.lPfx.slice(1+n)
      forkVtx.bVid[linkInx] = local

    elif linkVtx.ePfx.len == n + 1:
      # This extension `linkVtx` becomes obsolete
      forkVtx.bVid[linkInx] = linkVtx.eVid

    else:
      let local = db.vidFetch
      db.sTab[local] = linkVtx
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
    db.sTab[local] = leafLeg.wp.vtx

  # Update branch leg, ready to append more legs
  result = Hike(root: hike.root, legs: hike.legs)

  # Update in-beween glue linking `branch --[..]--> forkVtx`
  if 0 < n:
    let extVtx = VertexRef(
      vType: Extension,
      ePfx:  hike.tail.slice(0,n),
      eVid:  db.vidFetch)

    db.sTab[linkID] = extVtx

    result.legs.add Leg(
      nibble: -1,
      wp:     VidVtxPair(
        vid: linkID,
        vtx: extVtx))

    db.sTab[extVtx.eVid] = forkVtx
    result.legs.add Leg(
      nibble: leafInx.int8,
      wp:     VidVtxPair(
        vid: extVtx.eVid,
        vtx: forkVtx))
  else:
    db.sTab[linkID] = forkVtx
    result.legs.add Leg(
      nibble: leafInx.int8,
      wp:     VidVtxPair(
        vid: linkID,
        vtx: forkVtx))

  result.legs.add leafLeg


proc concatBranchAndLeaf(
    db: AristoDbRef;                   # Database, top layer
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
  if not brVtx.bVid[nibble].isZero:
    return Hike(error: MergeRootBranchLinkBusy)

  # Clear Merkle hashes (aka node keys) unless proof mode.
  if db.pPrf.len == 0:
    db.clearMerkleKeys(hike, brVid)
  elif brVid in db.pPrf:
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
  db.sTab[vid] = vtx
  result.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc topIsBranchAddLeaf(
    db: AristoDbRef;                   # Database, top layer
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
    if db.pPrf.len == 0:
      # Not much else that can be done here
      debug "Dangling leaf link, reused", branch=hike.legs[^1].wp.vid,
        nibble, linkID, leafPfx=hike.tail

    # Reuse placeholder entry in table
    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail,
      lData: payload)
    db.sTab[linkID] = vtx
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
    db: AristoDbRef;                   # Database, top layer
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
    db.sTab[extVid] = vtx
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
    if not linkID.isZero:
      return Hike(error: MergeRootBranchLinkBusy)

    # Clear Merkle hashes (aka node keys) unless proof mode
    if db.pPrf.len == 0:
      db.clearMerkleKeys(hike, brVid)
    elif brVid in db.pPrf:
      return Hike(error: MergeBranchProofModeLock)

    let
      vid = db.vidFetch
      vtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    brVtx.bVid[nibble] = vid
    db.sTab[vid] = vtx
    result.legs[^1].nibble = nibble
    result.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)


proc topIsEmptyAddLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # No path legs
    rootVtx: VertexRef;                # Root vertex
    payload: PayloadRef;               # Leaf data payload
     ): Hike =
  ## Append a `Leaf` vertex derived from the argument `payload` after the
  ## argument vertex `rootVtx` and append both the empty arguent `hike`.
  if rootVtx.vType == Branch:
    let nibble = hike.tail[0].int8
    if not rootVtx.bVid[nibble].isZero:
      return Hike(error: MergeRootBranchLinkBusy)
    let
      leafVid = db.vidFetch
      leafVtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    rootVtx.bVid[nibble] = leafVid
    db.sTab[leafVid] = leafVtx
    return Hike(
      root: hike.root,
      legs: @[Leg(wp: VidVtxPair(vtx: rootVtx, vid: hike.root), nibble: nibble),
              Leg(wp: VidVtxPair(vtx: leafVtx, vid: leafVid), nibble: -1)])

  db.insertBranch(hike, hike.root, rootVtx, payload)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    leaf: LeafKVP;                     # Leaf item to add to the database
      ): Hike =
  ## Merge the argument `leaf` key-value-pair into the top level vertex table
  ## of the database `db`. The field `pathKey` of the `leaf` argument is used
  ## to index the leaf vertex on the `Patricia Trie`. The field `payload` is
  ## stored with the leaf vertex in the database unless the leaf vertex exists
  ## already.
  ##
  proc setUpAsRoot(vid: VertexID): Hike =
    let
      vtx = VertexRef(
        vType: Leaf,
        lPfx:  leaf.pathTag.pathAsNibbles,
        lData: leaf.payload)
      wp = VidVtxPair(vid: vid, vtx: vtx)
    db.sTab[vid] = vtx
    Hike(root: vid, legs: @[Leg(wp: wp, nibble: -1)])

  if db.lRoot.isZero:
    result = db.vidFetch.setUpAsRoot() # bootstrap: new root ID
    db.lRoot = result.root

  elif db.lTab.haskey leaf.pathTag:
    result.error = MergeLeafPathCachedAlready

  else:
    let hike = leaf.pathTag.hikeUp(db.lRoot, db)

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
      let rootVtx = db.getVtx db.lRoot

      if rootVtx.isNil:
        result = db.lRoot.setUpAsRoot()    # bootstrap for existing root ID
      else:
        result = db.topIsEmptyAddLeaf(hike,rootVtx,leaf.payload)

  # Update leaf acccess cache
  if result.error == AristoError(0):
    db.lTab[leaf.pathTag] = result.legs[^1].wp.vid

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    leafs: openArray[LeafKVP];         # Leaf items to add to the database
      ): tuple[merged: int, dups: int, error: AristoError] =
  ## Variant of `merge()` for leaf lists.
  var (merged, dups) = (0, 0)
  for n,w in leafs:
    let hike = db.merge w
    if hike.error == AristoError(0):
      merged.inc
    elif hike.error == MergeLeafPathCachedAlready:
      dups.inc
    else:
      return (n,dups,hike.error)

  (merged, dups, AristoError(0))

# ---------------------

proc merge*(
    db: AristoDbRef;                   # Database, top layer
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
    var vid = db.pAmk.getOrDefault(key, VertexID(0))
    if vid == VertexID(0):
      vid = db.vidFetch
      db.pAmk[key] = vid
      db.kMap[vid] = key
    vid

  # Check whether the record is correct
  if node.error != AristoError(0):
    return err(node.error)

  # Verify `nodeKey`
  if nodeKey == EMPTY_ROOT_KEY:
    return err(MergeNodeKeyEmpty)

  # Check whether the node exists, already
  let nodeVid = db.pAmk.getOrDefault(nodeKey, VertexID(0))
  if nodeVid != VertexID(0) and db.sTab.hasKey nodeVid:
    return err(MergeNodeKeyCachedAlready)

  let
    vid = nodeKey.register
    vtx = node.to(VertexRef) # the vertex IDs need to be set up now (if any)

  case node.vType:
  of Leaf:
    discard
  of Extension:
    if not node.key[0].isEmpty:
      let eVid = db.pAmk.getOrDefault(node.key[0], VertexID(0))
      if eVid != VertexID(0):
        vtx.eVid = eVid
      else:
        vtx.eVid = node.key[0].register
  of Branch:
    for n in 0..15:
      if not node.key[n].isEmpty:
        let bVid = db.pAmk.getOrDefault(node.key[n], VertexID(0))
        if bVid != VertexID(0):
          vtx.bVid[n] = bVid
        else:
          vtx.bVid[n] = node.key[n].register

  db.pPrf.incl vid
  db.sTab[vid] = vtx
  ok vid

proc merge*(
    db: AristoDbRef;                   # Database, top layer
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

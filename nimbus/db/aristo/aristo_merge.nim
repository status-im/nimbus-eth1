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
## This module merges `HashID` values as hexary lookup paths into the
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
  std/[algorithm, sequtils, strutils, sets, tables],
  chronicles,
  eth/[common, trie/nibbles],
  stew/results,
  ../../sync/protocol,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_path, aristo_transcode,
       aristo_vid]

logScope:
  topics = "aristo-merge"

type
  LeafTiePayload* = object
    ## Generalised key-value pair for a sub-trie. The main trie is the
    ## sub-trie with `root=VertexID(1)`.
    leafTie*: LeafTie                  ## Full `Patricia Trie` path root-to-leaf
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
    let lbl = db.top.kMap.getOrVoid vid
    if lbl.isValid:
      db.top.kMap.del vid
      db.top.pAmk.del lbl
    elif db.getKeyBackend(vid).isOK:
      # Register for deleting on backend
      db.top.kMap[vid] = VOID_HASH_LABEL
      db.top.pAmk.del lbl

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
    # Clear Merkle hashes (aka hash keys) unless proof mode.
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
        lty = LeafTie(root: hike.root, path: rc.value)
      db.top.lTab[lty] = local         # update leaf path lookup cache
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
  if brVtx.bVid[nibble].isValid:
    return Hike(error: MergeRootBranchLinkBusy)

  # Clear Merkle hashes (aka hash keys) unless proof mode.
  if db.top.pPrf.len == 0:
    db.clearMerkleKeys(hike, brVid)
  elif brVid in db.top.pPrf:
    return Hike(error: MergeBranchProofModeLock) # Ooops

  # Append branch vertex
  result = Hike(root: hike.root, legs: hike.legs)
  result.legs.add Leg(wp: VidVtxPair(vtx: brVtx, vid: brVid), nibble: nibble)

  # Append leaf vertex
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
# Private functions: add Particia Trie leaf vertex
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

  if not linkVtx.isValid:
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

  if not brVtx.isValid:
    # Blind vertex, promote to leaf vertex.
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
    if linkID.isValid:
      return Hike(error: MergeRootBranchLinkBusy)

    # Clear Merkle hashes (aka hash keys) unless proof mode
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
    if rootVtx.bVid[nibble].isValid:
      return Hike(error: MergeRootBranchLinkBusy)

    # Clear Merkle hashes (aka hash keys) unless proof mode
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
# Private functions: add Merkle proof node
# ------------------------------------------------------------------------------

proc mergeNodeImpl(
    db: AristoDb;                      # Database, top layer
    hashKey: HashKey;                  # Merkel hash of node
    node: NodeRef;                     # Node derived from RLP representation
    rootVid: VertexID;                 # Current sub-trie
      ): Result[VertexID,AristoError]  =
  ## The function merges the argument hash key `hashKey` as expanded from the
  ## node RLP representation into the `Aristo Trie` database. The vertex is
  ## split off from the node and stored separately. So are the Merkle hashes.
  ## The vertex is labelled `locked`.
  ##
  ## The `node` argument is *not* checked, whether the vertex IDs have been
  ## allocated, already. If the node comes straight from the `decode()` RLP
  ## decoder as expected, these vertex IDs will be all zero.
  ##
  if node.error != AristoError(0):
    return err(node.error)
  if not rootVid.isValid:
    return err(MergeRootKeyInvalid)

  # Verify `hashKey`
  if not hashKey.isValid:
    return err(MergeHashKeyInvalid)

  # Make sure that the `vid<->hashLbl` reverse mapping has been cached,
  # already. This is provided for if the `nodes` are processed in the right
  # order `root->.. ->leaf`.
  var
    hashLbl = HashLabel(root: rootVid, key: hashKey)
    vid = db.top.pAmk.getOrVoid hashLbl
  if not vid.isValid:
    return err(MergeRevVidMustHaveBeenCached)

  let lbl = db.top.kMap.getOrVoid vid
  if lbl == hashLbl:
    if db.top.sTab.hasKey vid:
      # This is tyically considered OK
      return err(MergeHashKeyCachedAlready)
    # Otherwise proceed
  elif lbl.isValid:
    # Different key assigned => error
    return err(MergeHashKeyDiffersFromCached)

  let (vtx, hasVtx) = block:
    let vty = db.getVtx vid
    if vty.isValid:
      (vty, true)
    else:
      (node.to(VertexRef), false)

  # The `vertexID <-> hashLabel` mappings need to be set up now (if any)
  case node.vType:
  of Leaf:
    discard
  of Extension:
    if node.key[0].isValid:
      let eLbl = HashLabel(root: rootVid, key: node.key[0])
      if hasVtx:
        if not vtx.eVid.isValid:
          return err(MergeNodeVtxDiffersFromExisting)
        db.top.pAmk[eLbl] = vtx.eVid
      else:
        let eVid = db.top.pAmk.getOrVoid eLbl
        if eVid.isValid:
          vtx.eVid = eVid
        else:
          vtx.eVid = db.vidAttach eLbl
  of Branch:
    for n in 0..15:
      if node.key[n].isValid:
        let bLbl = HashLabel(root: rootVid, key: node.key[n])
        if hasVtx:
          if not vtx.bVid[n].isValid:
            return err(MergeNodeVtxDiffersFromExisting)
          db.top.pAmk[bLbl] = vtx.bVid[n]
        else:
          let bVid = db.top.pAmk.getOrVoid bLbl
          if bVid.isValid:
            vtx.bVid[n] = bVid
          else:
            vtx.bVid[n] = db.vidAttach bLbl

  db.top.pPrf.incl vid
  db.top.sTab[vid] = vtx
  ok vid

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(
    db: AristoDb;                      # Database, top layer
    leaf: LeafTiePayload;              # Leaf item to add to the database
      ): Hike =
  ## Merge the argument `leaf` key-value-pair into the top level vertex table
  ## of the database `db`. The field `pathKey` of the `leaf` argument is used
  ## to index the leaf vertex on the `Patricia Trie`. The field `payload` is
  ## stored with the leaf vertex in the database unless the leaf vertex exists
  ## already.
  ##
  if db.top.lTab.hasKey leaf.leafTie:
    result.error = MergeLeafPathCachedAlready

  else:
    let hike = leaf.leafTie.hikeUp(db)
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
      if rootVtx.isValid:
        result = db.topIsEmptyAddLeaf(hike,rootVtx,leaf.payload)

      else:
        # Bootstrap for existing root ID
        let wp = VidVtxPair(
          vid: hike.root,
          vtx: VertexRef(
            vType: Leaf,
            lPfx:  leaf.leafTie.path.to(NibblesSeq),
            lData: leaf.payload))
        db.top.sTab[wp.vid] = wp.vtx
        result = Hike(root: wp.vid, legs: @[Leg(wp: wp, nibble: -1)])

    # Update leaf acccess cache
    if result.error == AristoError(0):
      db.top.lTab[leaf.leafTie] = result.legs[^1].wp.vid

    # End else (1st level)

proc merge*(
    db: AristoDb;                      # Database, top layer
    leafs: openArray[LeafTiePayload];  # Leaf items to add to the database
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
    db: AristoDb;                      # Database, top layer
    proof: openArray[SnapProof];       # RLP encoded node records
    rootVid: VertexID;                 # Current sub-trie
      ): tuple[merged: int, dups: int, error: AristoError]
      {.gcsafe, raises: [RlpError].} =
  ## The function merges the argument `proof` list of RLP encoded node records
  ## into the `Aristo Trie` database. This function is intended to be used with
  ## the proof nodes as returened by `snap/1` messages.
  ##
  if not rootVid.isValid:
    return (0,0,MergeRootVidInvalid)
  let rootKey = db.getKey rootVid
  if not rootKey.isValid:
    return (0,0,MergeRootKeyInvalid)

  # Expand and collect hash keys and nodes
  var nodeTab: Table[HashKey,NodeRef]
  for w in proof:
    let
      key = w.Blob.digestTo(HashKey)
      node = w.Blob.decode(NodeRef)
    nodeTab[key] = node

  # Create a table with back links
  var
    backLink: Table[HashKey,HashKey]
    blindNodes: HashSet[HashKey]
  for (key,node) in nodeTab.pairs:
    case node.vType:
    of Leaf:
      blindNodes.incl key
    of Extension:
      if nodeTab.hasKey node.key[0]:
        backLink[node.key[0]] = key
      else:
        blindNodes.incl key
    of Branch:
      var isBlind = true
      for n in 0 .. 15:
        if nodeTab.hasKey node.key[n]:
          isBlind = false
          backLink[node.key[n]] = key
      if isBlind:
        blindNodes.incl key

  # Run over blind nodes and build chains from a blind/bottom level node up
  # to the root node. Select only chains that end up at the pre-defined root
  # node.
  var chains: seq[seq[HashKey]]
  for w in blindNodes:
    # Build a chain of nodes up to the root node
    var
      chain: seq[HashKey]
      nodeKey = w
    while nodeKey.isValid and nodeTab.hasKey nodeKey:
      chain.add nodeKey
      nodeKey = backLink.getOrDefault(nodeKey, VOID_HASH_KEY)
    if 0 < chain.len and chain[^1] == rootKey:
      chains.add chain

  # Make sure that the reverse lookup for the root vertex label is available.
  block:
    let
      lbl = HashLabel(root: rootVid, key: rootKey)
      vid = db.top.pAmk.getOrVoid lbl
    if not vid.isvalid:
      db.top.pAmk[lbl] = rootVid

  # Process over chains in reverse mode starting with the root node. This
  # allows the algorithm to find existing nodes on the backend.
  var
    seen: HashSet[HashKey]
    (merged, dups) = (0, 0)
  # Process the root ID which is common to all chains
  for chain in chains:
    for key in chain.reversed:
      if key in seen:
        discard
      else:
        seen.incl key
        let
          node = nodeTab.getOrDefault(key, NodeRef(nil))
          rc = db.mergeNodeImpl(key, node, rootVid)
        if rc.isOK:
          merged.inc
        elif rc.error == MergeHashKeyCachedAlready:
          dups.inc
        else:
          return (merged, dups, rc.error)

  (merged, dups, AristoError(0))

proc merge*(
    db: AristoDb;                      # Database, top layer
    rootKey: HashKey;                  # Merkle hash for root
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
  if not rootKey.isValid:
    return err(MergeRootKeyInvalid)

  if rootVid.isValid and rootVid != VertexID(1):
    let key = db.getKey rootVid
    if key == rootKey:
      return ok rootVid

    if not key.isValid:
      db.vidAttach(HashLabel(root: rootVid, key: rootKey), rootVid)
      return ok rootVid
  else:
    let key = db.getKey VertexID(1)
    if key == rootKey:
      return ok VertexID(1)

    # Otherwise assign unless valid
    if not key.isValid:
      db.vidAttach(HashLabel(root: VertexID(1), key: rootKey), VertexID(1))
      return ok VertexID(1)

    # Create and assign a new root key
    if not rootVid.isValid:
      return ok db.vidRoot(rootKey)

  err(MergeRootKeyDiffersForVid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  std/[algorithm, sequtils, strutils, sets, tables],
  chronicles,
  eth/[common, trie/nibbles],
  results,
  stew/keyed_queue,
  ../../sync/protocol/snap/snap_types,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_path, aristo_serialise,
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

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(
    rc: Result[Hike,AristoError];
    T: type Result[bool,AristoError];
      ): T =
  ## Return code converter
  if rc.isOk:
    ok true
  elif rc.error in {MergeLeafPathCachedAlready,
                    MergeLeafPathOnBackendAlready}:
    ok false
  else:
    err(rc.error)

# -----------

proc nullifyKey(
    db: AristoDbRef;                   # Database, top layer
    vid: VertexID;                     # Vertex IDs to clear
      ) =
  # Register for void hash (to be recompiled)
  let lbl = db.top.kMap.getOrVoid vid
  db.top.pAmk.del lbl
  db.top.kMap[vid] = VOID_HASH_LABEL
  db.top.dirty = true                  # Modified top level cache

proc clearMerkleKeys(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Implied vertex IDs to clear hashes for
    vid: VertexID;                     # Additionall vertex IDs to clear
      ) =
  for w in hike.legs.mapIt(it.wp.vid) & @[vid]:
    db.nullifyKey w

proc setVtxAndKey(
    db: AristoDbRef;                   # Database, top layer
    vid: VertexID;                     # Vertex IDs to add/clear
    vtx: VertexRef;                    # Vertex to add
      ) =
  db.top.sTab[vid] = vtx
  db.nullifyKey vid

# -----------

proc insertBranch(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Current state
    linkID: VertexID;                  # Vertex ID to insert
    linkVtx: VertexRef;                # Vertex to insert
    payload: PayloadRef;               # Leaf data payload
     ): Result[Hike,AristoError] =
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
    return err(MergeLeafGarbledHike)
  if linkVtx.xPfx.len == n:
    return err(MergeBranchLinkVtxPfxTooShort)

  # Provide and install `forkVtx`
  let
    forkVtx = VertexRef(vType: Branch)
    linkInx = linkVtx.xPfx[n]
    leafInx = hike.tail[n]
  var
    leafLeg = Leg(nibble: -1)

  # Will modify top level cache
  db.top.dirty = true

  # Install `forkVtx`
  block:
    # Clear Merkle hashes (aka hash keys) unless proof mode.
    if db.top.pPrf.len == 0:
      db.clearMerkleKeys(hike, linkID)
    elif linkID in db.top.pPrf:
      return err(MergeNonBranchProofModeLock)

    if linkVtx.vType == Leaf:
      # Update vertex path lookup
      let
        path = hike.legsTo(NibblesSeq) & linkVtx.lPfx
        rc = path.pathToTag()
      if rc.isErr:
        debug "Branch link leaf path garbled", linkID, path
        return err(MergeBranchLinkLeafGarbled)

      let
        local = db.vidFetch(pristine = true)
        lty = LeafTie(root: hike.root, path: rc.value)

      db.top.lTab[lty] = local         # update leaf path lookup cache
      db.setVtxAndKey(local, linkVtx)
      linkVtx.lPfx = linkVtx.lPfx.slice(1+n)
      forkVtx.bVid[linkInx] = local

    elif linkVtx.ePfx.len == n + 1:
      # This extension `linkVtx` becomes obsolete
      forkVtx.bVid[linkInx] = linkVtx.eVid

    else:
      let local = db.vidFetch
      db.setVtxAndKey(local, linkVtx)
      linkVtx.ePfx = linkVtx.ePfx.slice(1+n)
      forkVtx.bVid[linkInx] = local

  block:
    let local = db.vidFetch(pristine = true)
    forkVtx.bVid[leafInx] = local
    leafLeg.wp.vid = local
    leafLeg.wp.vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail.slice(1+n),
      lData: payload)
    db.setVtxAndKey(local, leafLeg.wp.vtx)

  # Update branch leg, ready to append more legs
  var okHike = Hike(root: hike.root, legs: hike.legs)

  # Update in-beween glue linking `branch --[..]--> forkVtx`
  if 0 < n:
    let extVtx = VertexRef(
      vType: Extension,
      ePfx:  hike.tail.slice(0,n),
      eVid:  db.vidFetch)

    db.setVtxAndKey(linkID, extVtx)

    okHike.legs.add Leg(
      nibble: -1,
      wp:     VidVtxPair(
        vid: linkID,
        vtx: extVtx))

    db.setVtxAndKey(extVtx.eVid, forkVtx)
    okHike.legs.add Leg(
      nibble: leafInx.int8,
      wp:     VidVtxPair(
        vid: extVtx.eVid,
        vtx: forkVtx))

  else:
    db.setVtxAndKey(linkID, forkVtx)
    okHike.legs.add Leg(
      nibble: leafInx.int8,
      wp:     VidVtxPair(
        vid: linkID,
        vtx: forkVtx))

  okHike.legs.add leafLeg
  ok okHike


proc concatBranchAndLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Path top has a `Branch` vertex
    brVid: VertexID;                   # Branch vertex ID from from `Hike` top
    brVtx: VertexRef;                  # Branch vertex, linked to from `Hike`
    payload: PayloadRef;               # Leaf data payload
      ): Result[Hike,AristoError] =
  ## Append argument branch vertex passed as argument `(brID,brVtx)` and then
  ## a `Leaf` vertex derived from the argument `payload`.
  ##
  if hike.tail.len == 0:
    return err(MergeBranchGarbledTail)

  let nibble = hike.tail[0].int8
  if brVtx.bVid[nibble].isValid:
    return err(MergeRootBranchLinkBusy)

  # Clear Merkle hashes (aka hash keys) unless proof mode.
  if db.top.pPrf.len == 0:
    db.clearMerkleKeys(hike, brVid)
  elif brVid in db.top.pPrf:
    return err(MergeBranchProofModeLock) # Ooops

  # Append branch vertex
  var okHike = Hike(root: hike.root, legs: hike.legs)
  okHike.legs.add Leg(wp: VidVtxPair(vtx: brVtx, vid: brVid), nibble: nibble)

  # Will modify top level cache
  db.top.dirty = true

  # Append leaf vertex
  let
    vid = db.vidFetch(pristine = true)
    vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail.slice(1),
      lData: payload)
  brVtx.bVid[nibble] = vid
  db.setVtxAndKey(brVid, brVtx)
  db.setVtxAndKey(vid, vtx)
  okHike.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)

  ok okHike

# ------------------------------------------------------------------------------
# Private functions: add Particia Trie leaf vertex
# ------------------------------------------------------------------------------

proc topIsBranchAddLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Path top has a `Branch` vertex
    payload: PayloadRef;               # Leaf data payload
      ): Result[Hike,AristoError] =
  ## Append a `Leaf` vertex derived from the argument `payload` after the top
  ## leg of the `hike` argument which is assumend to refert to a `Branch`
  ## vertex. If successful, the function returns the updated `hike` trail.
  if hike.tail.len == 0:
    return err(MergeBranchGarbledTail)

  let nibble = hike.legs[^1].nibble
  if nibble < 0:
    return err(MergeBranchGarbledNibble)

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

    # Will modify top level cache
    db.top.dirty = true

    # Reuse placeholder entry in table
    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail,
      lData: payload)
    db.setVtxAndKey(linkID, vtx)
    var okHike = Hike(root: hike.root, legs: hike.legs)
    okHike.legs.add Leg(wp: VidVtxPair(vid: linkID, vtx: vtx), nibble: -1)
    return ok(okHike)

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
      ): Result[Hike,AristoError] =
  ## Append a `Leaf` vertex derived from the argument `payload` after the top
  ## leg of the `hike` argument which is assumend to refert to a `Extension`
  ## vertex. If successful, the function returns the
  ## updated `hike` trail.
  let
    extVtx = hike.legs[^1].wp.vtx
    extVid = hike.legs[^1].wp.vid
    brVid = extVtx.eVid
    brVtx = db.getVtx brVid

  var okHike = Hike(root: hike.root, legs: hike.legs)

  if not brVtx.isValid:
    # Blind vertex, promote to leaf vertex.
    #
    #  --(extVid)--> <extVtx> --(brVid)--> nil
    #
    #  <-------- immutable -------------->
    #

    # Will modify top level cache
    db.top.dirty = true

    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  extVtx.ePfx & hike.tail,
      lData: payload)
    db.setVtxAndKey(extVid, vtx)
    okHike.legs[^1].wp.vtx = vtx

  elif brVtx.vType != Branch:
    return err(MergeBranchRootExpected)

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
      return err(MergeRootBranchLinkBusy)

    # Will modify top level cache
    db.top.dirty = true

    # Clear Merkle hashes (aka hash keys) unless proof mode
    if db.top.pPrf.len == 0:
      db.clearMerkleKeys(hike, brVid)
    elif brVid in db.top.pPrf:
      return err(MergeBranchProofModeLock)

    let
      vid = db.vidFetch(pristine = true)
      vtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    brVtx.bVid[nibble] = vid
    db.setVtxAndKey(brVid, brVtx)
    db.setVtxAndKey(vid, vtx)
    db.top.dirty = true # Modified top level cache
    okHike.legs.add Leg(wp: VidVtxPair(vtx: brVtx, vid: brVid), nibble: nibble)
    okHike.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)

  ok okHike


proc topIsEmptyAddLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # No path legs
    rootVtx: VertexRef;                # Root vertex
    payload: PayloadRef;               # Leaf data payload
     ): Result[Hike,AristoError] =
  ## Append a `Leaf` vertex derived from the argument `payload` after the
  ## argument vertex `rootVtx` and append both the empty arguent `hike`.
  if rootVtx.vType == Branch:
    let nibble = hike.tail[0].int8
    if rootVtx.bVid[nibble].isValid:
      return err(MergeRootBranchLinkBusy)

    # Will modify top level cache
    db.top.dirty = true

    # Clear Merkle hashes (aka hash keys) unless proof mode
    if db.top.pPrf.len == 0:
      db.clearMerkleKeys(hike, hike.root)
    elif hike.root in db.top.pPrf:
      return err(MergeBranchProofModeLock)

    let
      leafVid = db.vidFetch(pristine = true)
      leafVtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    rootVtx.bVid[nibble] = leafVid
    db.setVtxAndKey(hike.root, rootVtx)
    db.setVtxAndKey(leafVid, leafVtx)
    return ok Hike(
      root: hike.root,
      legs: @[Leg(wp: VidVtxPair(vtx: rootVtx, vid: hike.root), nibble: nibble),
              Leg(wp: VidVtxPair(vtx: leafVtx, vid: leafVid), nibble: -1)])

  db.insertBranch(hike, hike.root, rootVtx, payload)


proc updatePayload(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # No path legs
    leafTie: LeafTie;                  # Leaf item to add to the database
    payload: PayloadRef;               # Payload value
      ): Result[Hike,AristoError] =
  ## Update leaf vertex if payloads differ
  let leafLeg = hike.legs[^1]

  # Update payloads if they differ
  if leafLeg.wp.vtx.lData != payload:

    # Update vertex and hike
    let
      vid = leafLeg.wp.vid
      vtx = VertexRef(
        vType: Leaf,
        lPfx:  leafLeg.wp.vtx.lPfx,
        lData: payload)
    var hike = hike
    hike.legs[^1].backend = false
    hike.legs[^1].wp.vtx = vtx

    # Modify top level cache
    db.top.dirty = true
    db.setVtxAndKey(vid, vtx)
    db.top.lTab[leafTie] = vid
    db.clearMerkleKeys(hike, vid)
    ok hike

  elif leafLeg.backend:
    err(MergeLeafPathOnBackendAlready)

  else:
    err(MergeLeafPathCachedAlready)

# ------------------------------------------------------------------------------
# Private functions: add Merkle proof node
# ------------------------------------------------------------------------------

proc mergeNodeImpl(
    db: AristoDbRef;                   # Database, top layer
    hashKey: HashKey;                  # Merkel hash of node (or so)
    node: NodeRef;                     # Node derived from RLP representation
    rootVid: VertexID;                 # Current sub-trie
      ): Result[void,AristoError]  =
  ## The function merges the argument hash key `lid` as expanded from the
  ## node RLP representation into the `Aristo Trie` database. The vertex is
  ## split off from the node and stored separately. So are the Merkle hashes.
  ## The vertex is labelled `locked`.
  ##
  ## The `node` argument is *not* checked, whether the vertex IDs have been
  ## allocated, already. If the node comes straight from the `decode()` RLP
  ## decoder as expected, these vertex IDs will be all zero.
  ##
  ## This function expects that the parent for the argument node has already
  ## been installed, i.e. the top layer cache mapping
  ##
  ##     pAmk: {HashKey} -> {{VertexID}}
  ##
  ## has a result for the argument `node`. Also, the invers top layer cache
  ## mapping
  ##
  ##     sTab: {VertexID} -> {VertexRef}
  ##
  ## has no result for all images of the argument `node` under `pAmk`:
  ##
  # Check for error after RLP decoding
  doAssert node.error == AristoError(0)
  if not rootVid.isValid:
    return err(MergeRootKeyInvalid)

  # Verify `hashKey`
  if not hashKey.isValid:
    return err(MergeHashKeyInvalid)

  # Make sure that the `vid<->hashLbl` reverse mapping has been cached,
  # already. This is provided for if the `nodes` are processed in the right
  # order `root->.. ->leaf`.
  let
    hashLbl = HashLabel(root: rootVid, key: hashKey)
    vids = db.top.pAmk.getOrVoid(hashLbl).toSeq
    isRoot = rootVid in vids
  if vids.len == 0:
    return err(MergeRevVidMustHaveBeenCached)
  if isRoot and 1 < vids.len:
    # There can only be one root.
    return err(MergeHashKeyRevLookUpGarbled)

  # Use the first vertex ID from the `vis` list as representant for all others
  let lbl = db.top.kMap.getOrVoid vids[0]
  if lbl == hashLbl:
    if db.top.sTab.hasKey vids[0]:
      for n in 1 ..< vids.len:
        if not db.top.sTab.hasKey vids[n]:
          return err(MergeHashKeyRevLookUpGarbled)
      # This is tyically considered OK
      return err(MergeHashKeyCachedAlready)
    # Otherwise proceed
  elif lbl.isValid:
    # Different key assigned => error
    return err(MergeHashKeyDiffersFromCached)

  # While the vertex referred to by `vids[0]` does not exists in the top layer
  # cache it may well be in some lower layers or the backend. This typically
  # happens for the root node.
  var (vtx, hasVtx) = block:
    let vty = db.getVtx vids[0]
    if vty.isValid:
      (vty, true)
    else:
      (node.to(VertexRef), false)

  # Verify that all `vids` entries are similar
  for n in 1 ..< vids.len:
    let w = vids[n]
    if lbl != db.top.kMap.getOrVoid(w) or db.top.sTab.hasKey(w):
      return err(MergeHashKeyRevLookUpGarbled)
    if not hasVtx:
      # Prefer existing node which has all links available, already.
      let u = db.getVtx w
      if u.isValid:
        (vtx, hasVtx) = (u, true)

  # The `vertexID <-> hashLabel` mappings need to be set up now (if any)
  case node.vType:
  of Leaf:
    discard
  of Extension:
    if node.key[0].isValid:
      let eLbl = HashLabel(root: rootVid, key: node.key[0])
      if not hasVtx:
        # Brand new reverse lookup link for this vertex
        vtx.eVid = db.vidAttach eLbl
      elif not vtx.eVid.isValid:
        return err(MergeNodeVtxDiffersFromExisting)
      db.top.pAmk.append(eLbl, vtx.eVid)
  of Branch:
    for n in 0..15:
      if node.key[n].isValid:
        let bLbl = HashLabel(root: rootVid, key: node.key[n])
        if not hasVtx:
          # Brand new reverse lookup link for this vertex
          vtx.bVid[n] = db.vidAttach bLbl
        elif not vtx.bVid[n].isValid:
          return err(MergeNodeVtxDiffersFromExisting)
        db.top.pAmk.append(bLbl, vtx.bVid[n])

  for w in vids:
    db.top.pPrf.incl w
    if not hasVtx or db.getKey(w) != hashKey:
      db.top.sTab[w] = vtx.dup
      db.top.dirty = true # Modified top level cache

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    leafTie: LeafTie;                  # Leaf item to add to the database
    payload: PayloadRef;               # Payload value
      ): Result[Hike,AristoError] =
  ## Merge the argument `leafTie` key-value-pair into the top level vertex
  ## table of the database `db`. The field `path` of the `leafTie` argument is
  ## used to index the leaf vertex on the `Patricia Trie`. The field `payload`
  ## is stored with the leaf vertex in the database unless the leaf vertex
  ## exists already.
  ##
  # Check whether the leaf is on the database and payloads match
  block:
    let vid = db.top.lTab.getOrVoid leafTie
    if vid.isValid:
      let vtx = db.getVtx vid
      if vtx.isValid and vtx.lData == payload:
        return err(MergeLeafPathCachedAlready)

  let hike = leafTie.hikeUp(db).to(Hike)
  var okHike: Hike
  if 0 < hike.legs.len:
    case hike.legs[^1].wp.vtx.vType:
    of Branch:
      okHike = ? db.topIsBranchAddLeaf(hike, payload)
    of Leaf:
      if 0 < hike.tail.len:          # `Leaf` vertex problem?
        return err(MergeLeafGarbledHike)
      okHike = ? db.updatePayload(hike, leafTie, payload)
    of Extension:
      okHike = ? db.topIsExtAddLeaf(hike, payload)

  else:
    # Empty hike
    let rootVtx = db.getVtx hike.root
    if rootVtx.isValid:
      okHike = ? db.topIsEmptyAddLeaf(hike,rootVtx, payload)

    else:
      # Bootstrap for existing root ID
      let wp = VidVtxPair(
        vid: hike.root,
        vtx: VertexRef(
          vType: Leaf,
          lPfx:  leafTie.path.to(NibblesSeq),
          lData: payload))
      db.setVtxAndKey(wp.vid, wp.vtx)
      okHike = Hike(root: wp.vid, legs: @[Leg(wp: wp, nibble: -1)])

    # Double check the result until the code is more reliable
    block:
      let rc = okHike.to(NibblesSeq).pathToTag
      if rc.isErr or rc.value != leafTie.path:
        return err(MergeAssemblyFailed) # Ooops

  # Update leaf acccess cache
  db.top.lTab[leafTie] = okHike.legs[^1].wp.vid

  ok okHike


proc merge*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Even nibbled byte path
    payload: PayloadRef;               # Payload value
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(root,path)` arguments instead of a `LeafTie`
  ## object.
  let lty = LeafTie(root: root, path: ? path.pathToTag)
  db.merge(lty, payload).to(typeof result)

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(root,path)` arguments instead of a `LeafTie`.
  ## The argument `data` is stored as-is as a a `RawData` payload value.
  db.merge(root, path, PayloadRef(pType: RawData, rawBlob: @data))

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    leaf: LeafTiePayload;              # Leaf item to add to the database
      ): Result[bool,AristoError] =
  ## Variant of `merge()`. This function will not indicate if the leaf
  ## was cached, already.
  db.merge(leaf.leafTie, leaf.payload).to(typeof result)

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    leafs: openArray[LeafTiePayload];  # Leaf items to add to the database
      ): tuple[merged: int, dups: int, error: AristoError] =
  ## Variant of `merge()` for leaf lists.
  var (merged, dups) = (0, 0)
  for n,w in leafs:
    let rc = db.merge(w.leafTie, w.payload)
    if rc.isOk:
      merged.inc
    elif rc.error in {MergeLeafPathCachedAlready,
                      MergeLeafPathOnBackendAlready}:
      dups.inc
    else:
      return (n,dups,rc.error)

  (merged, dups, AristoError(0))

# ---------------------

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    proof: openArray[SnapProof];       # RLP encoded node records
    rootVid: VertexID;                 # Current sub-trie
      ): tuple[merged: int, dups: int, error: AristoError]
      {.gcsafe, raises: [RlpError].} =
  ## The function merges the argument `proof` list of RLP encoded node records
  ## into the `Aristo Trie` database. This function is intended to be used with
  ## the proof nodes as returened by `snap/1` messages.
  ##
  proc update(
      seen: var Table[HashKey,NodeRef];
      todo: var KeyedQueueNV[NodeRef];
      key: HashKey;
        ) {.gcsafe, raises: [RlpError].} =
    ## Check for embedded nodes, i.e. fully encoded node instead of a hash
    if key.isValid and key.len < 32:
      let lid = @key.digestTo(HashKey)
      if not seen.hasKey lid:
        let node = @key.decode(NodeRef)
        discard todo.append node
        seen[lid] = node

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
      node = rlp.decode(w.Blob,NodeRef)
    if node.error != AristoError(0):
      return (0,0,node.error)
    nodeTab[key] = node

    # Check for embedded nodes, i.e. fully encoded node instead of a hash
    var embNodes: KeyedQueueNV[NodeRef]
    discard embNodes.append node
    while true:
      let node = embNodes.shift.valueOr: break
      case node.vType:
      of Leaf:
        discard
      of Branch:
        for n in 0 .. 15:
          nodeTab.update(embNodes, node.key[n])
      of Extension:
        nodeTab.update(embNodes, node.key[0])

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
      nodeKey = backLink.getOrVoid nodeKey
    if 0 < chain.len and chain[^1] == rootKey:
      chains.add chain

  # Make sure that the reverse lookup for the root vertex label is available.
  block:
    let
      lbl = HashLabel(root: rootVid, key: rootKey)
      vids = db.top.pAmk.getOrVoid lbl
    if not vids.isValid:
      db.top.pAmk.append(lbl, rootVid)
      db.top.dirty = true # Modified top level cache

  # Process over chains in reverse mode starting with the root node. This
  # allows the algorithm to find existing nodes on the backend.
  var
    seen: HashSet[HashKey]
    (merged, dups) = (0, 0)
  # Process the root ID which is common to all chains
  for chain in chains:
    for key in chain.reversed:
      if key notin seen:
        seen.incl key
        let rc = db.mergeNodeImpl(key, nodeTab.getOrVoid key, rootVid)
        if rc.isOK:
          merged.inc
        elif rc.error == MergeHashKeyCachedAlready:
          dups.inc
        else:
          return (merged, dups, rc.error)

  (merged, dups, AristoError(0))

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    rootKey: Hash256;                  # Merkle hash for root
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

  let rootLink = rootKey.to(HashKey)

  if rootVid.isValid and rootVid != VertexID(1):
    let key = db.getKey rootVid
    if key.to(Hash256) == rootKey:
      return ok rootVid

    if not key.isValid:
      db.vidAttach(HashLabel(root: rootVid, key: rootLink), rootVid)
      return ok rootVid
  else:
    let key = db.getKey VertexID(1)
    if key.to(Hash256) == rootKey:
      return ok VertexID(1)

    # Otherwise assign unless valid
    if not key.isValid:
      db.vidAttach(HashLabel(root: VertexID(1), key: rootLink), VertexID(1))
      return ok VertexID(1)

    # Create and assign a new root key
    if not rootVid.isValid:
      let vid = db.vidFetch
      db.vidAttach(HashLabel(root: vid, key: rootLink), vid)
      return ok vid

  err(MergeRootKeyDiffersForVid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

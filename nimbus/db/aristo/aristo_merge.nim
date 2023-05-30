# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/tables,
  chronicles,
  eth/[common, trie/nibbles],
  stew/results,
  ../../sync/snap/range_desc,
  ./aristo_debug,
  "."/[aristo_desc, aristo_error, aristo_get, aristo_hike, aristo_path,
       aristo_vid]

logScope:
  topics = "aristo-leaf"

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
  ##   --(linkID)--> <linkVtx>
  ##
  ## will become either
  ##
  ##   --(linkID)-->
  ##        <extVtx>             --(local1)-->
  ##          <forkVtx>[linkInx] --(local2)--> <linkVtx>
  ##                   [leafInx] --(local3)--> <leafVtx>
  ##
  ## or in case that there is no common prefix
  ##
  ##   --(linkID)-->
  ##          <forkVtx>[linkInx] --(local2)--> <linkVtx>
  ##                   [leafInx] --(local3)--> <leafVtx>
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
    let local = db.vidFetch

    # Update vertex path lookup
    if linkVtx.vType == Leaf:
      let
        path = hike.legsTo(NibblesSeq) & linkVtx.lPfx
        rc = path.pathToTag()
      if rc.isErr:
        error "Branch link leaf path garbled", linkID, path
        return Hike(error: MergeBrLinkLeafGarbled)
      db.lTab[rc.value] = local        # update leaf path lookup cache

    forkVtx.bVid[linkInx] = local
    db.sTab[local] = linkVtx
    linkVtx.xPfx = linkVtx.xPfx.slice(1+n)
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


proc appendBranchAndLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Path top has a `Branch` vertex
    brID: VertexID;                    # Branch vertex ID from from `Hike` top
    brVtx: VertexRef;                  # Branch vertex, linked to from `Hike`
    payload: PayloadRef;               # Leaf data payload
      ): Hike =
  ## Append argument branch vertex passed as argument `(brID,brVtx)` and then
  ## a `Leaf` vertex derived from the argument `payload`.

  if hike.tail.len == 0:
    return Hike(error: MergeBranchGarbledTail)
  let nibble = hike.tail[0].int8
  if not brVtx.bVid[nibble].isZero:
    return Hike(error: MergeRootBranchLinkBusy)

  # Append branch node
  result = Hike(root: hike.root, legs: hike.legs)
  result.legs.add Leg(wp: VidVtxPair(vtx: brVtx, vid: brID), nibble: nibble)

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

proc hikeTopBranchAppendLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Path top has a `Branch` vertex
    payload: PayloadRef;               # Leaf data payload
    proofMode: bool;                   # May have dangling links
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

    # Busy slot, check for dangling link
    linkVtx = block:
      let rc = db.getVtxCascaded linkID
      if rc.isErr and not proofMode:
        # Not much else that can be done here
        error "Dangling leaf link, reused", branch=hike.legs[^1].wp.vid,
          nibble, linkID, leafPfx=hike.tail
      if rc.isErr or rc.value.isNil:
        # Reuse placeholder entry in table
        let vtx = VertexRef(
          vType: Leaf,
          lPfx:  hike.tail,
          lData: payload)
        db.sTab[linkID] = vtx
        result = Hike(root: hike.root, legs: hike.legs)
        result.legs.add Leg(wp: VidVtxPair(vid: linkID, vtx: vtx), nibble: -1)
        return
      rc.value

  # Slot link to a branch vertex should be handled by `hikeUp()`
  if linkVtx.vType == Branch:
    return db.appendBranchAndLeaf(hike, linkID, linkVtx, payload)

  db.insertBranch(hike, linkID, linkVtx, payload)


proc hikeTopExtensionAppendLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Path top has an `Extension` vertex
    payload: PayloadRef;               # Leaf data payload
      ): Hike =
  ## Append a `Leaf` vertex derived from the argument `payload` after the top
  ## leg of the `hike` argument which is assumend to refert to a `Extension`
  ## vertex. If successful, the function returns the
  ## updated `hike` trail.
  let
    parVtx = hike.legs[^1].wp.vtx
    parID = hike.legs[^1].wp.vid
    brVtx = db.getVtx parVtx.eVid

  result = Hike(root: hike.root, legs: hike.legs)

  if brVtx.isNil:
    # Blind vertex, promote to leaf node.
    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  parVtx.ePfx & hike.tail,
      lData: payload)
    db.sTab[parID] = vtx
    result.legs[^1].wp.vtx = vtx

  elif brVtx.vType != Branch:
    return Hike(error: MergeBranchRootExpected)

  else:
    let nibble = hike.tail[0].int8
    if not brVtx.bVid[nibble].isZero:
      return Hike(error: MergeRootBranchLinkBusy)
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


proc emptyHikeAppendLeaf(
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
    pathTag: NodeTag;                  # `Patricia Trie` path root-to-leaf
    payload: PayloadRef;               # Leaf data payload
    root = VertexID(0);                # Root node reference
    proofMode = false;                 # May have dangling links
    noisy = false;
      ): Hike =
  ## Merge the argument `leaf` record into the top level vertex table of the
  ## database `db`. The argument `pathKey` is used to index the leaf on the
  ## `Patricia Tree`. The argument `payload` is stored with the leaf vertex in
  ## the database unless the leaf vertex exists already.

  proc setUpAsRoot(vid: VertexID): Hike =
    let
      vtx = VertexRef(
        vType: Leaf,
        lPfx:  pathTag.pathAsNibbles,
        lData: payload)
      wp = VidVtxPair(vid: vid, vtx: vtx)
    db.sTab[vid] = vtx
    Hike(root: vid, legs: @[Leg(wp: wp, nibble: -1)])

  if root.isZero:
    if noisy: echo ">>> merge (1)"
    result = db.vidFetch.setUpAsRoot() # bootstrap: new root ID

  else:
    let hike = pathTag.hikeUp(root, db)
    if noisy: echo "<<< merge (2) >>>", "\n    ", hike.pp(db)

    if 0 < hike.legs.len:
      case hike.legs[^1].wp.vtx.vType:
      of Branch:
        if noisy: echo ">>> merge (3)"
        result = db.hikeTopBranchAppendLeaf(hike, payload, proofMode)
      of Leaf:
        if noisy: echo ">>> merge (4)"
        if 0 < hike.tail.len:          # `Leaf` vertex problem?
          return Hike(error: MergeLeafGarbledHike)
        result = hike
      of Extension:
        if noisy: echo ">>> merge (5)"
        result = db.hikeTopExtensionAppendLeaf(hike, payload)

    else:
      # Empty hike
      let rootVtx = db.getVtx root

      if rootVtx.isNil:
        if noisy: echo ">>> merge (6)"
        result = root.setUpAsRoot()    # bootstrap for existing root ID
      else:
        if noisy: echo ">>> merge (7)"
        result = db.emptyHikeAppendLeaf(hike, rootVtx, payload)

  # Update leaf acccess cache
  if result.error == AristoError(0):
    db.lTab[pathTag] = result.legs[^1].wp.vid


proc merge*(
    db: AristoDbRef;                   # Database, top layer
    nodeKey: NodeKey;                  # Merkel hash of node
    node: NodeRef;                     # Node derived from RLP representation
      ): Result[VertexID,AristoError]  =
  ## Merge a node key expanded from its RLP representation into the database.
  ##
  ## There is some rudimentaty check whether the `node` is consistent. It is
  ## *not* checked, whether the vertex IDs have been allocated, already. If
  ## the node comes straight from the `decode()` RLP decoder, these vertex IDs
  ## will be all zero.

  proc register(key: NodeKey): VertexID =
    db.pAmk.withValue(key,vidPtr):
      return vidPtr[]
    let vid = db.vidFetch
    db.pAmk[key] = vid
    db.kMap[vid] = key
    vid

  # Check whether the record is correct
  if node.error != AristoError(0):
    return err(node.error)

  # Verify `nodeKey`
  if nodeKey.isZero:
    return err(MergeNodeKeyZero)

  # Check whether the node exists, already
  db.pAmk.withValue(nodeKey,vidPtr):
    if db.sTab.hasKey vidPtr[]:
      return ok vidPtr[]

  let
    vid = nodeKey.register
    vtx = node.to(VertexRef) # the vertex IDs need to be set up now (if any)

  case node.vType:
  of Leaf:
    discard
  of Extension:
    if not node.key[0].isZero:
      db.pAmk.withValue(node.key[0],vidPtr):
        vtx.eVid = vidPtr[]
      do:
        vtx.eVid = node.key[0].register
  of Branch:
    for n in 0..15:
      if not node.key[n].isZero:
        db.pAmk.withValue(node.key[n],vidPtr):
          vtx.bVid[n] = vidPtr[]
        do:
          vtx.bVid[n] = node.key[n].register

  db.sTab[vid] = vtx
  ok vid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

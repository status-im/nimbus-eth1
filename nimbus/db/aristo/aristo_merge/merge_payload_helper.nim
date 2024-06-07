# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[sequtils, sets],
  eth/[common, trie/nibbles],
  results,
  ".."/[aristo_desc, aristo_get, aristo_hike, aristo_layers, aristo_vid]

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

proc differ(
    db: AristoDbRef;                   # Database, top layer
    p1, p2: PayloadRef;                # Payload values
      ): bool =
  ## Check whether payloads differ on the database.
  ## If `p1` is `RLP` serialised and `p2` is a raw blob compare serialsations.
  ## If `p1` is of account type and `p2` is serialised, translate `p2`
  ## to an account type and compare.
  ##
  if p1 == p2:
    return false

  # Adjust abd check for divergent types.
  if p1.pType != p2.pType:
    if p1.pType == AccountData:
      try:
        let
          blob = (if p2.pType == RlpData: p2.rlpBlob else: p2.rawBlob)
          acc = rlp.decode(blob, Account)
        if acc.nonce == p1.account.nonce and
           acc.balance == p1.account.balance and
           acc.codeHash == p1.account.codeHash and
           acc.storageRoot.isValid == p1.account.storageID.isValid:
          if not p1.account.storageID.isValid or
             acc.storageRoot.to(HashKey) == db.getKey p1.account.storageID:
            return false
      except RlpError:
        discard

    elif p1.pType == RlpData:
      if p2.pType == RawData and p1.rlpBlob == p2.rawBlob:
        return false

  true

# -----------

proc clearMerkleKeys(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Implied vertex IDs to clear hashes for
    vid: VertexID;                     # Additionall vertex IDs to clear
      ) =
  for w in hike.legs.mapIt(it.wp.vid) & @[vid]:
    db.layersResKey(hike.root, w)

proc setVtxAndKey*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;
    vid: VertexID;                     # Vertex IDs to add/clear
    vtx: VertexRef;                    # Vertex to add
      ) {.gcsafe.}

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

  # Install `forkVtx`
  block:
    # Clear Merkle hashes (aka hash keys) unless proof mode.
    if db.pPrf.len == 0:
      db.clearMerkleKeys(hike, linkID)
    elif linkID in db.pPrf:
      return err(MergeNonBranchProofModeLock)

    if linkVtx.vType == Leaf:
      # Double check path prefix
      if 64 < hike.legsTo(NibblesSeq).len + linkVtx.lPfx.len:
        return err(MergeBranchLinkLeafGarbled)

      let
        local = db.vidFetch(pristine = true)
        linkDup = linkVtx.dup

      db.setVtxAndKey(hike.root, local, linkDup)
      linkDup.lPfx = linkDup.lPfx.slice(1+n)
      forkVtx.bVid[linkInx] = local

    elif linkVtx.ePfx.len == n + 1:
      # This extension `linkVtx` becomes obsolete
      forkVtx.bVid[linkInx] = linkVtx.eVid

    else:
      let
        local = db.vidFetch
        linkDup = linkVtx.dup

      db.setVtxAndKey(hike.root, local, linkDup)
      linkDup.ePfx = linkDup.ePfx.slice(1+n)
      forkVtx.bVid[linkInx] = local

  block:
    let local = db.vidFetch(pristine = true)
    forkVtx.bVid[leafInx] = local
    leafLeg.wp.vid = local
    leafLeg.wp.vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail.slice(1+n),
      lData: payload)
    db.setVtxAndKey(hike.root, local, leafLeg.wp.vtx)

  # Update branch leg, ready to append more legs
  var okHike = Hike(root: hike.root, legs: hike.legs)

  # Update in-beween glue linking `branch --[..]--> forkVtx`
  if 0 < n:
    let extVtx = VertexRef(
      vType: Extension,
      ePfx:  hike.tail.slice(0,n),
      eVid:  db.vidFetch)

    db.setVtxAndKey(hike.root, linkID, extVtx)

    okHike.legs.add Leg(
      nibble: -1,
      wp:     VidVtxPair(
        vid: linkID,
        vtx: extVtx))

    db.setVtxAndKey(hike.root, extVtx.eVid, forkVtx)
    okHike.legs.add Leg(
      nibble: leafInx.int8,
      wp:     VidVtxPair(
        vid: extVtx.eVid,
        vtx: forkVtx))

  else:
    db.setVtxAndKey(hike.root, linkID, forkVtx)
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
  if db.pPrf.len == 0:
    db.clearMerkleKeys(hike, brVid)
  elif brVid in db.pPrf:
    return err(MergeBranchProofModeLock) # Ooops

  # Append branch vertex
  var okHike = Hike(root: hike.root, legs: hike.legs)
  okHike.legs.add Leg(wp: VidVtxPair(vtx: brVtx, vid: brVid), nibble: nibble)

  # Append leaf vertex
  let
    brDup = brVtx.dup
    vid = db.vidFetch(pristine = true)
    vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail.slice(1),
      lData: payload)
  brDup.bVid[nibble] = vid
  db.setVtxAndKey(hike.root, brVid, brDup)
  db.setVtxAndKey(hike.root, vid, vtx)
  okHike.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)

  ok okHike

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc setVtxAndKey*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;
    vid: VertexID;                     # Vertex IDs to add/clear
    vtx: VertexRef;                    # Vertex to add
      ) =
  db.layersPutVtx(root, vid, vtx)
  db.layersResKey(root, vid)

# ------------------------------------------------------------------------------
# Public functions: add Particia Trie leaf vertex
# ------------------------------------------------------------------------------

proc mergePayloadTopIsBranchAddLeaf*(
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
    parent = hike.legs[^1].wp.vid
    branch = hike.legs[^1].wp.vtx
    linkID = branch.bVid[nibble]
    linkVtx = db.getVtx linkID

  if not linkVtx.isValid:
    #
    #  .. <branch>[nibble] --(linkID)--> nil
    #
    #  <-------- immutable ------------> <---- mutable ----> ..
    #
    if db.pPrf.len == 0:
      # Not much else that can be done here
      raiseAssert "Dangling edge:" &
        " pfx=" & $hike.legsTo(hike.legs.len-1,NibblesSeq) &
        " branch=" & $parent &
        " nibble=" & $nibble &
        " edge=" & $linkID &
        " tail=" & $hike.tail

    # Reuse placeholder entry in table
    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  hike.tail,
      lData: payload)
    db.setVtxAndKey(hike.root, linkID, vtx)
    var okHike = Hike(root: hike.root, legs: hike.legs)
    okHike.legs.add Leg(wp: VidVtxPair(vid: linkID, vtx: vtx), nibble: -1)
    if parent notin db.pPrf:
      db.layersResKey(hike.root, parent)
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


proc mergePayloadTopIsExtAddLeaf*(
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

    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  extVtx.ePfx & hike.tail,
      lData: payload)
    db.setVtxAndKey(hike.root, extVid, vtx)
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

    # Clear Merkle hashes (aka hash keys) unless proof mode
    if db.pPrf.len == 0:
      db.clearMerkleKeys(hike, brVid)
    elif brVid in db.pPrf:
      return err(MergeBranchProofModeLock)

    let
      brDup = brVtx.dup
      vid = db.vidFetch(pristine = true)
      vtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    brDup.bVid[nibble] = vid
    db.setVtxAndKey(hike.root, brVid, brDup)
    db.setVtxAndKey(hike.root, vid, vtx)
    okHike.legs.add Leg(wp: VidVtxPair(vtx: brDup, vid: brVid), nibble: nibble)
    okHike.legs.add Leg(wp: VidVtxPair(vtx: vtx, vid: vid), nibble: -1)

  ok okHike


proc mergePayloadTopIsEmptyAddLeaf*(
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

    # Clear Merkle hashes (aka hash keys) unless proof mode
    if db.pPrf.len == 0:
      db.clearMerkleKeys(hike, hike.root)
    elif hike.root in db.pPrf:
      return err(MergeBranchProofModeLock)

    let
      rootDup = rootVtx.dup
      leafVid = db.vidFetch(pristine = true)
      leafVtx = VertexRef(
        vType: Leaf,
        lPfx:  hike.tail.slice(1),
        lData: payload)
    rootDup.bVid[nibble] = leafVid
    db.setVtxAndKey(hike.root, hike.root, rootDup)
    db.setVtxAndKey(hike.root, leafVid, leafVtx)
    return ok Hike(
      root: hike.root,
      legs: @[Leg(wp: VidVtxPair(vtx: rootDup, vid: hike.root), nibble: nibble),
              Leg(wp: VidVtxPair(vtx: leafVtx, vid: leafVid), nibble: -1)])

  db.insertBranch(hike, hike.root, rootVtx, payload)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergePayloadUpdate*(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # No path legs
    leafTie: LeafTie;                  # Leaf item to add to the database
    payload: PayloadRef;               # Payload value to add
      ): Result[Hike,AristoError] =
  ## Update leaf vertex if payloads differ
  let leafLeg = hike.legs[^1]

  # Update payloads if they differ
  if db.differ(leafLeg.wp.vtx.lData, payload):
    let vid = leafLeg.wp.vid
    if vid in db.pPrf:
      return err(MergeLeafProofModeLock)

    # Verify that the account leaf can be replaced
    if leafTie.root == VertexID(1):
      if leafLeg.wp.vtx.lData.pType != payload.pType:
        return err(MergeLeafCantChangePayloadType)
      if payload.pType == AccountData and
         payload.account.storageID != leafLeg.wp.vtx.lData.account.storageID:
        return err(MergeLeafCantChangeStorageID)

    # Update vertex and hike
    let vtx = VertexRef(
      vType: Leaf,
      lPfx:  leafLeg.wp.vtx.lPfx,
      lData: payload)
    var hike = hike
    hike.legs[^1].wp.vtx = vtx

    # Modify top level cache
    db.setVtxAndKey(hike.root, vid, vtx)
    db.clearMerkleKeys(hike, vid)
    ok hike

  elif db.layersGetVtx(leafLeg.wp.vid).isErr:
    err(MergeLeafPathOnBackendAlready)

  else:
    err(MergeLeafPathCachedAlready)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

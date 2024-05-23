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
  std/[algorithm, sequtils, strutils, sets, tables, typetraits],
  eth/[common, trie/nibbles],
  results,
  stew/keyed_queue,
  ../../sync/protocol/snap/snap_types,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_layers,
       aristo_path, aristo_serialise, aristo_utils, aristo_vid]

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

proc setVtxAndKey(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;
    vid: VertexID;                     # Vertex IDs to add/clear
    vtx: VertexRef;                    # Vertex to add
      ) =
  db.layersPutVtx(root, vid, vtx)
  db.layersResKey(root, vid)

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


proc updatePayload(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # No path legs
    leafTie: LeafTie;                  # Leaf item to add to the database
    payload: PayloadRef;               # Payload value
      ): Result[Hike,AristoError] =
  ## Update leaf vertex if payloads differ
  let leafLeg = hike.legs[^1]

  # Update payloads if they differ
  if db.differ(leafLeg.wp.vtx.lData, payload):
    let vid = leafLeg.wp.vid
    if vid in db.pPrf:
      return err(MergeLeafProofModeLock)

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
  ## This function expects that the parent for the argument `node` has already
  ## been installed.
  ##
  ## Caveat:
  ##   Proof of concept, not in production yet.
  ##
  # Check for error after RLP decoding
  doAssert node.error == AristoError(0)

  # Verify arguments
  if not rootVid.isValid:
    return err(MergeRootKeyInvalid)
  if not hashKey.isValid:
    return err(MergeHashKeyInvalid)

  # Make sure that the `vid<->key` reverse mapping is updated.
  let vid = db.layerGetProofVidOrVoid hashKey
  if not vid.isValid:
    return err(MergeRevVidMustHaveBeenCached)

  # Use the vertex ID `vid` to be populated by the argument root node
  let key = db.layersGetKeyOrVoid vid
  if key.isValid and key != hashKey:
    return err(MergeHashKeyDiffersFromCached)

  # Set up vertex.
  let (vtx, newVtxFromNode) = block:
    let vty = db.getVtx vid
    if vty.isValid:
      (vty, false)
    else:
      (node.to(VertexRef), true)

  # The `vertexID <-> hashKey` mappings need to be set up now (if any)
  case node.vType:
  of Leaf:
    # Check whether there is need to convert the payload to `Account` payload
    if rootVid == VertexID(1) and newVtxFromNode:
      try:
        let
          # `aristo_serialise.read()` always decodes raw data payloaf
          acc = rlp.decode(node.lData.rawBlob, Account)
          pyl = PayloadRef(
            pType: AccountData,
            account: AristoAccount(
              nonce:    acc.nonce,
              balance:  acc.balance,
              codeHash: acc.codeHash))
        if acc.storageRoot.isValid:
          var sid = db.layerGetProofVidOrVoid acc.storageRoot.to(HashKey)
          if not sid.isValid:
            sid = db.vidFetch
            db.layersPutProof(sid, acc.storageRoot.to(HashKey))
          pyl.account.storageID = sid
        vtx.lData = pyl
      except RlpError:
        return err(MergeNodeAccountPayloadError)
  of Extension:
    if node.key[0].isValid:
      let eKey = node.key[0]
      if newVtxFromNode:
        vtx.eVid = db.layerGetProofVidOrVoid eKey
        if not vtx.eVid.isValid:
          # Brand new reverse lookup link for this vertex
          vtx.eVid = db.vidFetch
      elif not vtx.eVid.isValid:
        return err(MergeNodeVidMissing)
      else:
        let yEke = db.getKey vtx.eVid
        if yEke.isValid and eKey != yEke:
          return err(MergeNodeVtxDiffersFromExisting)
      db.layersPutProof(vtx.eVid, eKey)
  of Branch:
    for n in 0..15:
      if node.key[n].isValid:
        let bKey = node.key[n]
        if newVtxFromNode:
          vtx.bVid[n] = db.layerGetProofVidOrVoid bKey
          if not vtx.bVid[n].isValid:
            # Brand new reverse lookup link for this vertex
            vtx.bVid[n] = db.vidFetch
        elif not vtx.bVid[n].isValid:
          return err(MergeNodeVidMissing)
        else:
          let yEkb = db.getKey vtx.bVid[n]
          if yEkb.isValid and yEkb != bKey:
            return err(MergeNodeVtxDiffersFromExisting)
        db.layersPutProof(vtx.bVid[n], bKey)

  # Store and lock vertex
  db.layersPutProof(vid, key, vtx)
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergePayload*(
    db: AristoDbRef;                   # Database, top layer
    leafTie: LeafTie;                  # Leaf item to add to the database
    payload: PayloadRef;               # Payload value
    accPath: PathID;                   # Needed for accounts payload
      ): Result[Hike,AristoError] =
  ## Merge the argument `leafTie` key-value-pair into the top level vertex
  ## table of the database `db`. The field `path` of the `leafTie` argument is
  ## used to index the leaf vertex on the `Patricia Trie`. The field `payload`
  ## is stored with the leaf vertex in the database unless the leaf vertex
  ## exists already.
  ##
  ## For a `payload.root` with `VertexID` greater than `LEAST_FREE_VID`, the
  ## sub-tree generated by `payload.root` is considered a storage trie linked
  ## to an account leaf referred to by a valid `accPath` (i.e. different from
  ## `VOID_PATH_ID`.) In that case, an account must exists. If there is payload
  ## of type `AccountData`, its `storageID` field must be unset or equal to the
  ## `payload.root` vertex ID.
  ##
  if LEAST_FREE_VID <= leafTie.root.distinctBase:
    ? db.registerAccount(leafTie.root, accPath)
  elif not leafTie.root.isValid:
    return err(MergeRootMissing)

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
      db.setVtxAndKey(hike.root, wp.vid, wp.vtx)
      okHike = Hike(root: wp.vid, legs: @[Leg(wp: wp, nibble: -1)])

    # Double check the result until the code is more reliable
    block:
      let rc = okHike.to(NibblesSeq).pathToTag
      if rc.isErr or rc.value != leafTie.path:
        return err(MergeAssemblyFailed) # Ooops

  ok okHike


proc mergePayload*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Even nibbled byte path
    payload: PayloadRef;               # Payload value
    accPath = VOID_PATH_ID;            # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(root,path)` arguments instead of a `LeafTie`
  ## object.
  let lty = LeafTie(root: root, path: ? path.pathToTag)
  db.mergePayload(lty, payload, accPath).to(typeof result)


proc merge*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
    accPath: PathID;                   # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(root,path)` arguments instead of a `LeafTie`.
  ## The argument `data` is stored as-is as a `RawData` payload value.
  let pyl = PayloadRef(pType: RawData, rawBlob: @data)
  db.mergePayload(root, path, pyl, accPath)

proc mergeAccount*(
    db: AristoDbRef;                   # Database, top layer
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(VertexID(1),path)` arguments instead of a
  ## `LeafTie`. The argument `data` is stored as-is as a `RawData` payload
  ## value.
  let pyl = PayloadRef(pType: RawData, rawBlob: @data)
  db.mergePayload(VertexID(1), path, pyl, VOID_PATH_ID)


proc mergeLeaf*(
    db: AristoDbRef;                   # Database, top layer
    leaf: LeafTiePayload;              # Leaf item to add to the database
    accPath = VOID_PATH_ID;            # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Variant of `merge()`. This function will not indicate if the leaf
  ## was cached, already.
  db.mergePayload(leaf.leafTie, leaf.payload, accPath).to(typeof result)

# ---------------------

proc merge*(
    db: AristoDbRef;                   # Database, top layer
    proof: openArray[SnapProof];       # RLP encoded node records
    rootVid = VertexID(0);             # Current sub-trie
      ): Result[int, AristoError]
      {.gcsafe, raises: [RlpError].} =
  ## The function merges the argument `proof` list of RLP encoded node records
  ## into the `Aristo Trie` database. This function is intended to be used with
  ## the proof nodes as returened by `snap/1` messages.
  ##
  ## If there is no root vertex ID passed, the function tries to find out what
  ## the root hashes are and allocates new vertices with static IDs `$2`, `$3`,
  ## etc.
  ##
  ## Caveat:
  ##   Proof of concept, not in production yet.
  ##
  proc update(
      seen: var Table[HashKey,NodeRef];
      todo: var KeyedQueueNV[NodeRef];
      key: HashKey;
        ) {.gcsafe, raises: [RlpError].} =
    ## Check for embedded nodes, i.e. fully encoded node instead of a hash.
    ## They need to be treated as full nodes, here.
    if key.isValid and key.len < 32:
      let lid = @(key.data).digestTo(HashKey)
      if not seen.hasKey lid:
        let node = @(key.data).decode(NodeRef)
        discard todo.append node
        seen[lid] = node

  let rootKey = block:
    if rootVid.isValid:
      let vidKey = db.getKey rootVid
      if not vidKey.isValid:
        return err(MergeRootKeyInvalid)
      # Make sure that the reverse lookup for the root vertex key is available.
      if not db.layerGetProofVidOrVoid(vidKey).isValid:
        return err(MergeProofInitMissing)
      vidKey
    else:
      VOID_HASH_KEY

  # Expand and collect hash keys and nodes and parent indicator
  var
    nodeTab: Table[HashKey,NodeRef]
    rootKeys: HashSet[HashKey] # Potential root node hashes
  for w in proof:
    let
      key = w.Blob.digestTo(HashKey)
      node = rlp.decode(w.Blob,NodeRef)
    if node.error != AristoError(0):
      return err(node.error)
    nodeTab[key] = node
    rootKeys.incl key

    # Check for embedded nodes, i.e. fully encoded node instead of a hash.
    # They will be added as full nodes to the `nodeTab[]`.
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
        rootKeys.excl node.key[0] # predecessor => not root
      else:
        blindNodes.incl key
    of Branch:
      var isBlind = true
      for n in 0 .. 15:
        if nodeTab.hasKey node.key[n]:
          isBlind = false
          backLink[node.key[n]] = key
          rootKeys.excl node.key[n] # predecessor => not root
      if isBlind:
        blindNodes.incl key

  # If it exists, the root key must be in the set `mayBeRoot` in order
  # to work.
  var roots: Table[HashKey,VertexID]
  if rootVid.isValid:
    if rootKey notin rootKeys:
      return err(MergeRootKeyNotInProof)
    roots[rootKey] = rootVid
  elif rootKeys.len == 0:
    return err(MergeRootKeysMissing)
  else:
    # Add static root keys different from VertexID(1)
    var count = 2
    for key in rootKeys.items:
      while true:
        # Check for already allocated nodes
        let vid1 = db.layerGetProofVidOrVoid key
        if vid1.isValid:
          roots[key] = vid1
          break
        # Use the next free static free vertex ID
        let vid2 = VertexID(count)
        count.inc
        if not db.getKey(vid2).isValid:
          db.layersPutProof(vid2, key)
          roots[key] = vid2
          break
        if LEAST_FREE_VID <= count:
          return err(MergeRootKeysOverflow)

  # Run over blind nodes and build chains from a blind/bottom level node up
  # to the root node. Select only chains that end up at the pre-defined root
  # node.
  var
    accounts: seq[seq[HashKey]] # This one separated, to be processed last
    chains: seq[seq[HashKey]]
  for w in blindNodes:
    # Build a chain of nodes up to the root node
    var
      chain: seq[HashKey]
      nodeKey = w
    while nodeKey.isValid and nodeTab.hasKey nodeKey:
      chain.add nodeKey
      nodeKey = backLink.getOrVoid nodeKey
    if 0 < chain.len and chain[^1] in roots:
      if roots.getOrVoid(chain[0]) == VertexID(1):
        accounts.add chain
      else:
        chains.add chain

  # Process over chains in reverse mode starting with the root node. This
  # allows the algorithm to find existing nodes on the backend.
  var
    seen: HashSet[HashKey]
    merged = 0
  # Process the root ID which is common to all chains
  for chain in chains & accounts:
    let chainRootVid = roots.getOrVoid chain[^1]
    for key in chain.reversed:
      if key notin seen:
        seen.incl key
        let node = nodeTab.getOrVoid key
        db.mergeNodeImpl(key, node, chainRootVid).isOkOr:
          return err(error)
        merged.inc

  ok merged


proc merge*(
    db: AristoDbRef;                   # Database, top layer
    rootHash: Hash256;                 # Merkle hash for root
    rootVid = VertexID(0);             # Optionally, force root vertex ID
      ): Result[VertexID,AristoError] =
  ## Set up a `rootKey` associated with a vertex ID for use with proof nodes.
  ##
  ## If argument `rootVid` is unset then a new dybamic root vertex (i.e.
  ## the ID will be at least `LEAST_FREE_VID`) will be installed.
  ##
  ## Otherwise, if the argument `rootVid` is set then a sub-trie with root
  ## `rootVid` is checked for. An error is returned if it is set up already
  ## with a different `rootHash`.
  ##
  ## Upon successful return, the vertex ID assigned to the root key is returned.
  ##
  ## Caveat:
  ##   Proof of concept, not in production yet.
  ##
  let rootKey = rootHash.to(HashKey)

  if rootVid.isValid:
    let key = db.getKey rootVid
    if key.isValid:
      if rootKey.isValid and key != rootKey:
        # Cannot use installed root key differing from hash argument
        return err(MergeRootKeyDiffersForVid)
      # Confirm root ID and key for proof nodes processing
      db.layersPutProof(rootVid, key) # note that `rootKey` might be void
      return ok rootVid

    if not rootHash.isValid:
      return err(MergeRootArgsIncomplete)
    if db.getVtx(rootVid).isValid:
      # Cannot use verify root key for existing root vertex
      return err(MergeRootKeyMissing)

    # Confirm root ID and hash key for proof nodes processing
    db.layersPutProof(rootVid, rootKey)
    return ok rootVid

  if not rootHash.isValid:
    return err(MergeRootArgsIncomplete)

  # Now there is no root vertex ID, only the hash argument.
  # So Create and assign a new root key.
  let vid = db.vidFetch
  db.layersPutProof(vid, rootKey)
  return ok vid


proc merge*(
    db: AristoDbRef;                   # Database, top layer
    rootVid: VertexID;                 # Root ID
      ): Result[VertexID,AristoError] =
  ## Variant of `merge()` for missing `rootHash`
  db.merge(EMPTY_ROOT_HASH, rootVid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

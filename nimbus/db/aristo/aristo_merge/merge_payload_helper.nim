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

import eth/common, results, ".."/[aristo_desc, aristo_get, aristo_layers, aristo_vid]

# ------------------------------------------------------------------------------
# Private getters & setters
# ------------------------------------------------------------------------------

proc xPfx(vtx: VertexRef): NibblesBuf =
  case vtx.vType
  of Leaf:
    vtx.lPfx
  of Extension:
    vtx.ePfx
  of Branch:
    raiseAssert "oops"

# -----------

proc layersPutLeaf(
    db: AristoDbRef, rvid: RootedVertexID, path: NibblesBuf, payload: LeafPayload
): VertexRef =
  let vtx = VertexRef(vType: Leaf, lPfx: path, lData: payload)
  db.layersPutVtx(rvid, vtx)
  vtx

proc insertBranch(
    db: AristoDbRef, # Database, top layer
    linkID: RootedVertexID, # Vertex ID to insert
    linkVtx: VertexRef, # Vertex to insert
    path: NibblesBuf,
    payload: LeafPayload, # Leaf data payload
): Result[VertexRef, AristoError] =
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
  if linkVtx.xPfx.len == 0:
    return err(MergeBranchLinkVtxPfxTooShort)

  let n = linkVtx.xPfx.sharedPrefixLen path
  # Verify minimum requirements
  doAssert n < path.len

  # Provide and install `forkVtx`
  let
    forkVtx = VertexRef(vType: Branch)
    linkInx = linkVtx.xPfx[n]
    leafInx = path[n]

  # Install `forkVtx`
  block:
    if linkVtx.vType == Leaf:
      let
        local = db.vidFetch(pristine = true)
        linkDup = linkVtx.dup

      linkDup.lPfx = linkVtx.lPfx.slice(1 + n)
      forkVtx.bVid[linkInx] = local
      db.layersPutVtx((linkID.root, local), linkDup)
    elif linkVtx.ePfx.len == n + 1:
      # This extension `linkVtx` becomes obsolete
      forkVtx.bVid[linkInx] = linkVtx.eVid
    else:
      let
        local = db.vidFetch
        linkDup = linkVtx.dup

      linkDup.ePfx = linkDup.ePfx.slice(1 + n)
      forkVtx.bVid[linkInx] = local
      db.layersPutVtx((linkID.root, local), linkDup)

  let leafVtx = block:
    let local = db.vidFetch(pristine = true)
    forkVtx.bVid[leafInx] = local
    db.layersPutLeaf((linkID.root, local), path.slice(1 + n), payload)

  # Update in-beween glue linking `branch --[..]--> forkVtx`
  if 0 < n:
    let
      vid = db.vidFetch()
      extVtx = VertexRef(vType: Extension, ePfx: path.slice(0, n), eVid: vid)
    db.layersPutVtx(linkID, extVtx)
    db.layersPutVtx((linkID.root, vid), forkVtx)
  else:
    db.layersPutVtx(linkID, forkVtx)

  ok(leafVtx)

proc concatBranchAndLeaf(
    db: AristoDbRef, # Database, top layer
    brVid: RootedVertexID, # Branch vertex ID from from `Hike` top
    brVtx: VertexRef, # Branch vertex, linked to from `Hike`
    path: NibblesBuf,
    payload: LeafPayload, # Leaf data payload
): Result[VertexRef, AristoError] =
  ## Append argument branch vertex passed as argument `(brID,brVtx)` and then
  ## a `Leaf` vertex derived from the argument `payload`.
  ##
  if path.len == 0:
    return err(MergeBranchGarbledTail)

  let nibble = path[0].int8
  doAssert not brVtx.bVid[nibble].isValid

  let
    brDup = brVtx.dup
    vid = db.vidFetch(pristine = true)

  brDup.bVid[nibble] = vid

  db.layersPutVtx(brVid, brDup)
  ok db.layersPutLeaf((brVid.root, vid), path.slice(1), payload)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergePayloadImpl*(
    db: AristoDbRef, # Database, top layer
    root: VertexID, # MPT state root
    path: openArray[byte], # Leaf item to add to the database
    payload: LeafPayload, # Payload value
): Result[VertexRef, AristoError] =
  ## Merge the argument `(root,path)` key-value-pair into the top level vertex
  ## table of the database `db`. The `path` argument is used to address the
  ## leaf vertex with the payload. It is stored or updated on the database
  ## accordingly.
  ##
  var
    path = NibblesBuf.fromBytes(path)
    cur = root
    touched: array[NibblesBuf.high + 1, VertexID]
    pos = 0
    vtx = db.getVtxRc((root, cur)).valueOr:
      if error != GetVtxNotFound:
        return err(error)

      # We're at the root vertex and there is no data - this must be a fresh
      # VertexID!
      return ok db.layersPutLeaf((root, cur), path, payload)

  template resetKeys() =
    # Reset cached hashes of touched verticies
    for i in 0 ..< pos:
      db.layersResKey((root, touched[pos - i - 1]))

  while path.len > 0:
    # Clear existing merkle keys along the traversal path
    touched[pos] = cur
    pos += 1

    case vtx.vType
    of Leaf:
      let leafVtx =
        if path == vtx.lPfx:
          # Replace the current vertex with a new payload

          if vtx.lData == payload:
            # TODO is this still needed? Higher levels should already be doing
            #      these checks
            return err(MergeLeafPathCachedAlready)

          var payload = payload
          if root == VertexID(1):
            # TODO can we avoid this hack? it feels like the caller should already
            #      have set an appropriate stoID - this "fixup" feels risky,
            #      specially from a caching point of view
            payload.stoID = vtx.lData.stoID

          db.layersPutLeaf((root, cur), path, payload)

        else:
          # Turn leaf into branch, leaves with possible ext prefix
          ? db.insertBranch((root, cur), vtx, path, payload)

      resetKeys()
      return ok(leafVtx)

    of Extension:
      if vtx.ePfx.len == path.sharedPrefixLen(vtx.ePfx):
        cur = vtx.eVid
        path = path.slice(vtx.ePfx.len)
        vtx = ?db.getVtxRc((root, cur))
      else:
        let leafVtx = ? db.insertBranch((root, cur), vtx, path, payload)

        resetKeys()
        return ok(leafVtx)
    of Branch:
      let
        nibble = path[0]
        next = vtx.bVid[nibble]

      if next.isValid:
        cur = next
        path = path.slice(1)
        vtx = ?db.getVtxRc((root, next))
      else:
        let leafVtx = ? db.concatBranchAndLeaf((root, cur), vtx, path, payload)
        resetKeys()
        return ok(leafVtx)

  err(MergeHikeFailed)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

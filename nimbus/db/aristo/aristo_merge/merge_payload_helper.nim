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
  of Leaf: vtx.lPfx
  of Branch: vtx.ePfx

# -----------

proc layersPutLeaf(
    db: AristoDbRef, rvid: RootedVertexID, path: NibblesBuf, payload: LeafPayload
): VertexRef =
  let vtx = VertexRef(vType: Leaf, lPfx: path, lData: payload)
  db.layersPutVtx(rvid, vtx)
  vtx

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
    (vtx, _) = db.getVtxRc((root, cur)).valueOr:
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

    let n = path.sharedPrefixLen(vtx.xPfx)
    case vtx.vType
    of Leaf:
      let leafVtx =
        if n == vtx.lPfx.len:
          # Same path - replace the current vertex with a new payload

          if vtx.lData == payload:
            # TODO is this still needed? Higher levels should already be doing
            #      these checks
            return err(MergeLeafPathCachedAlready)

          if root == VertexID(1):
            var payload = payload.dup()
            # TODO can we avoid this hack? it feels like the caller should already
            #      have set an appropriate stoID - this "fixup" feels risky,
            #      specially from a caching point of view
            payload.stoID = vtx.lData.stoID
            db.layersPutLeaf((root, cur), path, payload)
          else:
            db.layersPutLeaf((root, cur), path, payload)
        else:
          # Turn leaf into a branch (or extension) then insert the two leaves
          # into the branch
          let branch = VertexRef(vType: Branch, ePfx: path.slice(0, n))
          block: # Copy of existing leaf node, now one level deeper
            let local = db.vidFetch()
            branch.bVid[vtx.lPfx[n]] = local
            discard db.layersPutLeaf((root, local), vtx.lPfx.slice(n + 1), vtx.lData)

          let leafVtx = block: # Newly inserted leaf node
            let local = db.vidFetch()
            branch.bVid[path[n]] = local
            db.layersPutLeaf((root, local), path.slice(n + 1), payload)

          # Put the branch at the vid where the leaf was
          db.layersPutVtx((root, cur), branch)

          leafVtx

      resetKeys()
      return ok(leafVtx)
    of Branch:
      if vtx.ePfx.len == n:
        # The existing branch is a prefix of the new entry
        let
          nibble = path[vtx.ePfx.len]
          next = vtx.bVid[nibble]

        if next.isValid:
          cur = next
          path = path.slice(n + 1)
          (vtx, _) = ?db.getVtxRc((root, next))
        else:
          # There's no vertex at the branch point - insert the payload as a new
          # leaf and update the existing branch
          let
            local = db.vidFetch()
            leafVtx = db.layersPutLeaf((root, local), path.slice(n + 1), payload)
            brDup = vtx.dup()

          brDup.bVid[nibble] = local
          db.layersPutVtx((root, cur), brDup)

          resetKeys()
          return ok(leafVtx)
      else:
        # Partial path match - we need to split the existing branch at
        # the point of divergence, inserting a new branch
        let branch = VertexRef(vType: Branch, ePfx: path.slice(0, n))
        block: # Copy the existing vertex and add it to the new branch
          let local = db.vidFetch()
          branch.bVid[vtx.ePfx[n]] = local

          db.layersPutVtx(
            (root, local),
            VertexRef(vType: Branch, ePfx: vtx.ePfx.slice(n + 1), bVid: vtx.bVid),
          )

        let leafVtx = block: # add the new entry
          let local = db.vidFetch()
          branch.bVid[path[n]] = local
          db.layersPutLeaf((root, local), path.slice(n + 1), payload)

        db.layersPutVtx((root, cur), branch)

        resetKeys()
        return ok(leafVtx)

  err(MergeHikeFailed)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

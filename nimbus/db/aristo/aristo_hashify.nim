# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie Merkleisation
## ========================================
##
## For the current state of the `Patricia Trie`, keys (equivalent to hashes)
## are associated with the vertex IDs. Existing key associations are checked
## (i.e. recalculated and compared) unless the ID is locked. In the latter
## case, the key is assumed to be correct without checking.
##
## The association algorithm is an optimised version of:
##
## * For all leaf vertices, label them with parent vertex so that there are
##   chains from the leafs to the root vertex.
##
## * Apply a width-first traversal starting with the set of leafs vertices
##   compiling the keys to associate with by hashing the current vertex.
##
##   Apperently, keys (aka hashes) can be compiled for leaf vertices. For the
##   other vertices, the keys can be compiled if all the children keys are
##   known which is assured by the nature of the width-first traversal method.
##
## For production, this algorithm is slightly optimised:
##
## * For each leaf vertex, calculate the chain from the leaf to the root vertex.
##   + Starting at the leaf, calculate the key for each vertex towards the root
##     vertex as long as possible.
##   + Stash the rest of the partial chain to be completed later
##
## * While there is a partial chain left, use the ends towards the leaf nodes
##   and calculate the remaining keys (which results in a width-first
##   traversal, again.)

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, tables],
  chronicles,
  eth/common,
  stew/results,
  ./aristo_debug,
  "."/[aristo_constants, aristo_desc, aristo_error, aristo_get, aristo_hike,
       aristo_transcode]

logScope:
  topics = "aristo-hashify"

# ------------------------------------------------------------------------------
# Private helper, debugging
# ------------------------------------------------------------------------------

proc pp(t: Table[VertexID,VertexID]): string =
  result = "{"
  for a in toSeq(t.keys).mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let b = t.getOrDefault(a, VertexID(0))
    if b != VertexID(0):
      result &= "(" & a.pp & "," & b.pp & "),"
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc toNode(vtx: VertexRef; db: AristoDbRef): Result[NodeRef,void] =
  case vtx.vType:
  of Leaf:
    return ok NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    for n in 0 .. 15:
      if vtx.bVid[n].isZero:
        node.key[n] = EMPTY_ROOT_KEY
      else:
        let key = db.kMap.getOrDefault(vtx.bVid[n], EMPTY_ROOT_KEY)
        if key != EMPTY_ROOT_KEY:
          node.key[n] = key
          continue
        return err()
    return ok node
  of Extension:
    if not vtx.eVid.isZero:
      let key = db.kMap.getOrDefault(vtx.eVid, EMPTY_ROOT_KEY)
      if key != EMPTY_ROOT_KEY:
        let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vtx.eVid)
        node.key[0] = key
        return ok node

proc leafToRootHasher(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Hike for labelling leaf..root
      ): Result[int,(VertexID,AristoError)] =
  ## Returns the index of the first node that could not be hashed
  for n in (hike.legs.len-1).countDown(0):
    let
      wp = hike.legs[n].wp
      rc = wp.vtx.toNode db
    if rc.isErr:
      return ok n
    # Vertices marked proof nodes need not be checked
    if wp.vid in db.pPrf:
      continue

    # Check against existing key, or store new key
    let key = rc.value.encode.digestTo(NodeKey)
    let vfyKey = db.kMap.getOrDefault(wp.vid, EMPTY_ROOT_KEY)
    if vfyKey == EMPTY_ROOT_KEY:
      db.pAmk[key] = wp.vid
      db.kMap[wp.vid] = key
    elif key != vfyKey:
      let error = HashifyExistingHashMismatch
      debug "hashify failed", vid=wp.vid, key, expected=vfyKey, error
      return err((wp.vid,error))

  ok -1 # all could be hashed

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hashifyClear*(
    db: AristoDbRef;                   # Database, top layer
    locksOnly = false;                 # If `true`, then clear only proof locks
      ) =
  ## Clear all `Merkle` hashes from the argument database layer `db`.
  if not locksOnly:
    db.pAmk.clear
    db.kMap.clear
  db.pPrf.clear


proc hashify*(
    db: AristoDbRef;                   # Database, top layer
    rootKey = EMPTY_ROOT_KEY;          # Optional root key
      ): Result[NodeKey,(VertexID,AristoError)] =
  ## Add keys to the  `Patricia Trie` so that it becomes a `Merkle Patricia
  ## Tree`. If successful, the function returns the key (aka Merkle hash) of
  ## the root vertex.
  var
    thisRootKey = EMPTY_ROOT_KEY

    # Width-first leaf-to-root traversal structure
    backLink: Table[VertexID,VertexID]
    downMost: Table[VertexID,VertexID]

  for (pathTag,vid) in db.lTab.pairs:
    let hike = pathTag.hikeUp(db.lRoot,db)
    if hike.error != AristoError(0):
      return err((VertexID(0),hike.error))

    # Hash as much of the `hike` as possible
    let n = block:
      let rc = db.leafToRootHasher hike
      if rc.isErr:
        return err(rc.error)
      rc.value

    if 0 < n:
      # Backtrack and register remaining nodes
      #
      # hike.legs: (leg[0], leg[1], .., leg[n-1], leg[n], ..)
      #               |       |           |          |
      #               | <---- |     <---- |   <----  |
      #               |                   |          |
      #               |     backLink[]    | downMost |
      #
      downMost[hike.legs[n].wp.vid] = hike.legs[n-1].wp.vid
      for u in (n-1).countDown(1):
        backLink[hike.legs[u].wp.vid] = hike.legs[u-1].wp.vid

    elif thisRootKey == EMPTY_ROOT_KEY:
      let rootVid = hike.legs[0].wp.vid
      thisRootKey = db.kMap.getOrDefault(rootVid, EMPTY_ROOT_KEY)

      if thisRootKey != EMPTY_ROOT_KEY:
        if rootKey != EMPTY_ROOT_KEY and rootKey != thisRootKey:
          return err((rootVid, HashifyRootHashMismatch))

        if db.lRoot == VertexID(0):
          db.lRoot = rootVid
        elif db.lRoot != rootVid:
          return err((rootVid,HashifyRootVidMismatch))

  # At least one full path leaf..root should have succeeded with labelling
  if thisRootKey == EMPTY_ROOT_KEY:
    return err((VertexID(0),HashifyLeafToRootAllFailed))

  # Update remaining hashes
  var n = 0 # for logging
  while 0 < downMost.len:
    var
      redo: Table[VertexID,VertexID]
      done: HashSet[VertexID]

    for (fromVid,toVid) in downMost.pairs:
      # Try to convert vertex to a node. This is possible only if all link
      # references have Merkle hashes.
      #
      # Also `db.getVtx(fromVid)` => not nil as it was fetched earlier, already
      let rc = db.getVtx(fromVid).toNode(db)
      if rc.isErr:
        # Cannot complete with this node, so do it later
        redo[fromVid] = toVid

      else:
        # Register Hashes
        let nodeKey = rc.value.encode.digestTo(NodeKey)

        # Update Merkle hash (aka `nodeKey`)
        let fromKey = db.kMap.getOrDefault(fromVid, EMPTY_ROOT_KEY)
        if fromKey == EMPTY_ROOT_KEY:
          db.pAmk[nodeKey] = fromVid
          db.kMap[fromVid] = nodeKey
        elif nodeKey != fromKey:
          let error = HashifyExistingHashMismatch
          debug "hashify failed", vid=fromVid, key=nodeKey,
            expected=fromKey.pp, error
          return err((fromVid,error))

        done.incl fromVid

        # Proceed with back link
        let nextVid = backLink.getOrDefault(toVid, VertexID(0))
        if nextVid != VertexID(0):
          redo[toVid] = nextVid

    # Make sure that the algorithm proceeds
    if done.len == 0:
      let error = HashifyCannotComplete
      return err((VertexID(0),error))

    # Clean up dups from `backLink` and restart `downMost`
    for vid in done.items:
      backLink.del vid
    downMost = redo

  ok thisRootKey

# ------------------------------------------------------------------------------
# Public debugging functions
# ------------------------------------------------------------------------------

proc hashifyCheck*(
    db: AristoDbRef;                   # Database, top layer
    relax = false;                     # Check existing hashes only
      ): Result[void,(VertexID,AristoError)] =
  ## Verify that the Merkle hash keys are either completely missing or
  ## match all known vertices on the argument database layer `db`.
  if not relax:
    for (vid,vtx) in db.sTab.pairs:
      let rc = vtx.toNode(db)
      if rc.isErr:
        return err((vid,HashifyCheckVtxIncomplete))

      let key = db.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
      if key == EMPTY_ROOT_KEY:
        return err((vid,HashifyCheckVtxHashMissing))
      if key != rc.value.encode.digestTo(NodeKey):
        return err((vid,HashifyCheckVtxHashMismatch))

      let revVid = db.pAmk.getOrDefault(key, VertexID(0))
      if revVid == VertexID(0):
        return err((vid,HashifyCheckRevHashMissing))
      if revVid != vid:
        return err((vid,HashifyCheckRevHashMismatch))

  elif 0 < db.pPrf.len:
    for vid in db.pPrf:
      let vtx = db.sTab.getOrDefault(vid, VertexRef(nil))
      if vtx == VertexRef(nil):
        return err((vid,HashifyCheckVidVtxMismatch))

      let rc = vtx.toNode(db)
      if rc.isErr:
        return err((vid,HashifyCheckVtxIncomplete))

      let key = db.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
      if key == EMPTY_ROOT_KEY:
        return err((vid,HashifyCheckVtxHashMissing))
      if key != rc.value.encode.digestTo(NodeKey):
        return err((vid,HashifyCheckVtxHashMismatch))

      let revVid = db.pAmk.getOrDefault(key, VertexID(0))
      if revVid == VertexID(0):
        return err((vid,HashifyCheckRevHashMissing))
      if revVid != vid:
        return err((vid,HashifyCheckRevHashMismatch))

  else:
    for (vid,key) in db.kMap.pairs:
      let vtx = db.getVtx vid
      if not vtx.isNil:
        let rc = vtx.toNode(db)
        if rc.isOk:
          if key != rc.value.encode.digestTo(NodeKey):
            return err((vid,HashifyCheckVtxHashMismatch))

          let revVid = db.pAmk.getOrDefault(key, VertexID(0))
          if revVid == VertexID(0):
            return err((vid,HashifyCheckRevHashMissing))
          if revVid != vid:
            return err((vid,HashifyCheckRevHashMismatch))

  if db.pAmk.len != db.kMap.len:
    var knownKeys: HashSet[VertexID]
    for (key,vid) in db.pAmk.pairs:
      if not db.kMap.hasKey(vid):
        return err((vid,HashifyCheckRevVtxMissing))
      if vid in knownKeys:
        return err((vid,HashifyCheckRevVtxDup))
      knownKeys.incl vid
    return err((VertexID(0),HashifyCheckRevCountMismatch)) # should not apply(!)

  if 0 < db.pAmk.len and not relax and db.pAmk.len != db.sTab.len:
    return err((VertexID(0),HashifyCheckVtxCountMismatch))

  for vid in db.pPrf:
    if not db.kMap.hasKey(vid):
      return err((vid,HashifyCheckVtxLockWithoutKey))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

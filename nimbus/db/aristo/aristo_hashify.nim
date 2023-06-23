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
## * While there is a partial chain left, use the ends towards the leaf
##   vertices and calculate the remaining keys (which results in a width-first
##   traversal, again.)

{.push raises: [].}

import
  std/[sequtils, sets, strutils, tables],
  chronicles,
  eth/common,
  stew/results,
  "."/[aristo_constants, aristo_desc, aristo_get, aristo_hike,
       aristo_transcode, aristo_vid]

type
  BackVidValRef = ref object
    root: VertexID                      ## Root vertex
    onBe: bool                          ## Table key vid refers to backend
    toVid: VertexID                     ## Next/follow up vertex

  BackVidTab =
    Table[VertexID,BackVidValRef]

logScope:
  topics = "aristo-hashify"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Hashify " & info

func getOrVoid(tab: BackVidTab; vid: VertexID): BackVidValRef =
  tab.getOrDefault(vid, BackVidValRef(nil))

func isValid(brv: BackVidValRef): bool =
  brv != BackVidValRef(nil)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc toNode(vtx: VertexRef; db: AristoDb): Result[NodeRef,void] =
  case vtx.vType:
  of Leaf:
    return ok NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    for n in 0 .. 15:
      if vtx.bVid[n].isValid:
        let key = db.getKey vtx.bVid[n]
        if key.isValid:
          node.key[n] = key
          continue
        return err()
      else:
        node.key[n] = VOID_HASH_KEY
    return ok node
  of Extension:
    if vtx.eVid.isValid:
      let key = db.getKey vtx.eVid
      if key.isValid:
        let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vtx.eVid)
        node.key[0] = key
        return ok node


proc updateHashKey(
    db: AristoDb;                      # Database, top layer
    root: VertexID;                    # Root ID
    vid: VertexID;                     # Vertex ID to check for
    expected: HashKey;                 # Hash key for vertex address by `vid`
    backend: bool;                     # Set `true` id vertex is on backend
      ): Result[void,AristoError] =
  ## Update the argument hash key `expected` for the vertex addressed by `vid`.
  ##
  # If the Merkle hash has been cached locally, already it must match.
  block:
    let key = db.top.kMap.getOrVoid(vid).key
    if key.isValid:
      if key != expected:
        let error = HashifyExistingHashMismatch
        debug logTxt "hash update failed", vid, key, expected, error
        return err(error)
      return ok()

  # If the vertex had been cached locally, there would be no locally cached
  # Merkle hash key. It will be created at the bottom end of the function.
  #
  # So there remains tha case when vertex is available on the backend only.
  # The Merkle hash not cached locally. It might be overloaded (and eventually
  # overwitten.)
  if backend:
    # Ok, vertex is on the backend.
    let rc = db.getKeyBackend vid
    if rc.isOk:
      let key = rc.value
      if key == expected:
        return ok()

      # This step is a error in the sense that something the on the backend
      # is fishy. There should not be contradicting Merkle hashes. Throwing
      # an error heres would lead to a deadlock so we correct it.
      debug "correcting backend hash key mismatch", vid, key, expected
      # Proceed `vidAttach()`, below

    elif rc.error != GetKeyNotFound:
      debug logTxt "backend key fetch failed", vid, expected, error=rc.error
      return err(rc.error)

    else:
      discard
      # Proceed `vidAttach()`, below

  # Othwise there is no Merkle hash, so create one with the `expected` key
  db.vidAttach(HashLabel(root: root, key: expected), vid)
  ok()


proc leafToRootHasher(
    db: AristoDb;                      # Database, top layer
    hike: Hike;                        # Hike for labelling leaf..root
      ): Result[int,(VertexID,AristoError)] =
  ## Returns the index of the first node that could not be hashed
  for n in (hike.legs.len-1).countDown(0):
    let
      wp = hike.legs[n].wp
      bg = hike.legs[n].backend
      rc = wp.vtx.toNode db
    if rc.isErr:
      return ok n

    # Vertices marked proof nodes need not be checked
    if wp.vid in db.top.pPrf:
      continue

    # Check against existing key, or store new key
    let
      key = rc.value.encode.digestTo(HashKey)
      rx = db.updateHashKey(hike.root, wp.vid, key, bg)
    if rx.isErr:
      return err((wp.vid,rx.error))

  ok -1 # all could be hashed

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hashifyClear*(
    db: AristoDb;                      # Database, top layer
    locksOnly = false;                 # If `true`, then clear only proof locks
      ) =
  ## Clear all `Merkle` hashes from the  `db` argument database top layer.
  if not locksOnly:
    db.top.pAmk.clear
    db.top.kMap.clear
  db.top.pPrf.clear


proc hashify*(
    db: AristoDb;                      # Database, top layer
      ): Result[HashSet[VertexID],(VertexID,AristoError)] =
  ## Add keys to the  `Patricia Trie` so that it becomes a `Merkle Patricia
  ## Tree`. If successful, the function returns the key (aka Merkle hash) of
  ## the root vertex.
  var
    roots: HashSet[VertexID]
    completed: HashSet[VertexID]

    # Width-first leaf-to-root traversal structure
    backLink: BackVidTab
    downMost: BackVidTab

  for (lky,vid) in db.top.lTab.pairs:
    let hike = lky.hikeUp(db)
    if hike.error != AristoError(0):
      return err((vid,hike.error))

    roots.incl hike.root

    # Hash as much of the `hike` as possible
    let n = block:
      let rc = db.leafToRootHasher hike
      if rc.isErr:
        return err(rc.error)
      rc.value

    if 0 < n:
      # Backtrack and register remaining nodes. Note that in case *n == 0*, the
      # root vertex has not been fully resolved yet.
      #
      # hike.legs: (leg[0], leg[1], .., leg[n-1], leg[n], ..)
      #               |       |           |          |
      #               | <---- |     <---- |   <----  |
      #               |                   |          |
      #               |     backLink[]    | downMost |
      #
      downMost[hike.legs[n].wp.vid] = BackVidValRef(
        root:  hike.root,
        onBe:  hike.legs[n].backend,
        toVid: hike.legs[n-1].wp.vid)
      for u in (n-1).countDown(1):
        backLink[hike.legs[u].wp.vid] = BackVidValRef(
          root:  hike.root,
          onBe:  hike.legs[u].backend,
          toVid: hike.legs[u-1].wp.vid)

    elif n < 0:
      completed.incl hike.root

  # At least one full path leaf..root should have succeeded with labelling
  # for each root.
  if completed.len < roots.len:
    return err((VertexID(0),HashifyLeafToRootAllFailed))

  # Update remaining hashes
  while 0 < downMost.len:
    var
      redo: BackVidTab
      done: HashSet[VertexID]

    for (vid,val) in downMost.pairs:
      # Try to convert vertex to a node. This is possible only if all link
      # references have Merkle hashes.
      #
      # Also `db.getVtx(vid)` => not nil as it was fetched earlier, already
      let rc = db.getVtx(vid).toNode(db)
      if rc.isErr:
        # Cannot complete with this vertex, so do it later
        redo[vid] = val

      else:
        # Update Merkle hash
        let
          key = rc.value.encode.digestTo(HashKey)
          rx = db.updateHashKey(val.root, vid, key, val.onBe)
        if rx.isErr:
          return err((vid,rx.error))

        done.incl vid

        # Proceed with back link
        let nextItem = backLink.getOrVoid val.toVid
        if nextItem.isValid:
          redo[val.toVid] = nextItem

    # Make sure that the algorithm proceeds
    if done.len == 0:
      let error = HashifyCannotComplete
      return err((VertexID(0),error))

    # Clean up dups from `backLink` and restart `downMost`
    for vid in done.items:
      backLink.del vid
    downMost = redo

  ok completed

# ------------------------------------------------------------------------------
# Public debugging functions
# ------------------------------------------------------------------------------

proc hashifyCheck*(
    db: AristoDb;                      # Database, top layer
    relax = false;                     # Check existing hashes only
      ): Result[void,(VertexID,AristoError)] =
  ## Verify that the Merkle hash keys are either completely missing or
  ## match all known vertices on the argument database layer `db`.
  if not relax:
    for (vid,vtx) in db.top.sTab.pairs:
      let rc = vtx.toNode(db)
      if rc.isErr:
        return err((vid,HashifyCheckVtxIncomplete))

      let lbl = db.top.kMap.getOrVoid vid
      if not lbl.isValid:
        return err((vid,HashifyCheckVtxHashMissing))
      if lbl.key != rc.value.encode.digestTo(HashKey):
        return err((vid,HashifyCheckVtxHashMismatch))

      let revVid = db.top.pAmk.getOrVoid lbl
      if not revVid.isValid:
        return err((vid,HashifyCheckRevHashMissing))
      if revVid != vid:
        return err((vid,HashifyCheckRevHashMismatch))

  elif 0 < db.top.pPrf.len:
    for vid in db.top.pPrf:
      let vtx = db.top.sTab.getOrVoid vid
      if not vtx.isValid:
        return err((vid,HashifyCheckVidVtxMismatch))

      let rc = vtx.toNode(db)
      if rc.isErr:
        return err((vid,HashifyCheckVtxIncomplete))

      let lbl = db.top.kMap.getOrVoid vid
      if not lbl.isValid:
        return err((vid,HashifyCheckVtxHashMissing))
      if lbl.key != rc.value.encode.digestTo(HashKey):
        return err((vid,HashifyCheckVtxHashMismatch))

      let revVid = db.top.pAmk.getOrVoid lbl
      if not revVid.isValid:
        return err((vid,HashifyCheckRevHashMissing))
      if revVid != vid:
        return err((vid,HashifyCheckRevHashMismatch))

  else:
    for (vid,lbl) in db.top.kMap.pairs:
      if lbl.isValid:                              # Otherwise to be deleted
        let vtx = db.getVtx vid
        if vtx.isValid:
          let rc = vtx.toNode(db)
          if rc.isOk:
            if lbl.key != rc.value.encode.digestTo(HashKey):
              return err((vid,HashifyCheckVtxHashMismatch))

            let revVid = db.top.pAmk.getOrVoid lbl
            if not revVid.isValid:
              return err((vid,HashifyCheckRevHashMissing))
            if revVid != vid:
              return err((vid,HashifyCheckRevHashMismatch))

  # Some `kMap[]` entries may ne void indicating backend deletion
  let kMapCount = db.top.kMap.values.toSeq.filterIt(it.isValid).len

  if db.top.pAmk.len != kMapCount:
    var knownKeys: HashSet[VertexID]
    for (key,vid) in db.top.pAmk.pairs:
      if not db.top.kMap.hasKey(vid):
        return err((vid,HashifyCheckRevVtxMissing))
      if vid in knownKeys:
        return err((vid,HashifyCheckRevVtxDup))
      knownKeys.incl vid
    return err((VertexID(0),HashifyCheckRevCountMismatch)) # should not apply(!)

  if 0 < db.top.pAmk.len and not relax and db.top.pAmk.len < db.top.sTab.len:
    # Cannot have less changes than cached entries
    return err((VertexID(0),HashifyCheckVtxCountMismatch))

  for vid in db.top.pPrf:
    if not db.top.kMap.hasKey(vid):
      return err((vid,HashifyCheckVtxLockWithoutKey))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

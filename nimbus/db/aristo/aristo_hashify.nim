# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
## The folllowing properties are required from the top layer cache.
##
## * All recently (i.e. not saved to backend) added entries must have an
##   `lTab[]` entry with `(root-vertex,path,leaf-vertex-ID)`.
##
## * All recently (i.e. not saved to backend) deleted entries must have an
##   `lTab[]` entry with `(root-vertex,path,VertexID(0))`.
##
## * All vertices where the key (aka Merkle hash) has changed must have a
##   top layer cache `kMap[]` entry `(vertex-ID,VOID_HASH_LABEL)` indicating
##   that there is no key available for this vertex. This also applies for
##   backend verices where the key has changed while the structural logic
##   did not change.
##
## The association algorithm is an optimised version of:
##
## * For all leaf vertices which have all child links on the top layer cache
##   where the node keys (aka hashes) can be compiled, proceed with the parent
##   vertex. Note that a top layer cache vertex can only have a key on the top
##   top layer cache (whereas a bachend b
##
##   Apparently, keys (aka hashes) can be compiled for leaf vertices. The same
##   holds for follow up vertices where the child keys were available, alteady.
##   This process stops when a vertex has children on the backend or children
##   lead to a chain not sorted, yet.
##
## * For the remaining vertex chains (where the process stopped) up to the root
##   vertex, set up a width-first schedule starting at the vertex where the
##   previous chain broke off and follow up to the root vertex.
##
## * Follow the width-first schedule fo labelling all vertices with a hash key.
##
## Note that there are some tweaks for `proof` nodes with incomplete tries and
## handling of possible stray vertices on the top layer cache left over from
## deletion processes.
##
{.push raises: [].}

import
  std/[sequtils, sets, strutils, tables],
  chronicles,
  eth/common,
  results,
  stew/byteutils,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_serialise, aristo_utils,
       aristo_vid]

type
  FollowUpVid = object
    ## Link item: VertexID -> VertexID
    root: VertexID                  ## Root vertex, might be void unless known
    toVid: VertexID                 ## Valid next/follow up vertex

  BackVidTab =
    Table[VertexID,FollowUpVid]

  WidthFirstForest = object
    ## Collected width first search trees
    root: HashSet[VertexID]         ## Top level, root targets
    pool: BackVidTab                ## Upper links pool
    base: BackVidTab                ## Width-first leaf level links

  DfReport = object
    ## Depth first traversal report tracing back a hike with
    ## `leafToRootCrawler()`
    legInx: int                     ## First leg that failed to resolve
    unresolved: seq[VertexID]       ## List of unresolved links

const
  SubTreeSearchDepthMax = 64

logScope:
  topics = "aristo-hashify"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Hashify " & info


func getOrVoid(tab: BackVidTab; vid: VertexID): FollowUpVid =
  tab.getOrDefault(vid, FollowUpVid())

func isValid(w: FollowUpVid): bool =
  w.toVid.isValid

func contains(wff: WidthFirstForest; vid: VertexID): bool =
  vid in wff.base or vid in wff.pool or vid in wff.root

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateHashKey(
    db: AristoDbRef;                   # Database, top layer
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
  # So there remains the case when vertex is available on the backend only.
  # The Merkle hash not cached locally. It might be overloaded (and eventually
  # overwitten.)
  if backend:
    # Ok, vertex is on the backend.
    let rc = db.getKeyBE vid
    if rc.isOk:
      if rc.value == expected:
        return ok()

      # Changes on the upper layers overload the lower layers. Some hash keys
      # on the backend will have become obsolete which is corrected here.
      #
      # Proceed `vidAttach()`, below

    elif rc.error != GetKeyNotFound:
      debug logTxt "backend key fetch failed", vid, expected, error=rc.error
      return err(rc.error)

    else:
      discard
      # Proceed `vidAttach()`, below

  # Othwise there is no Merkle hash, so create one with the `expected` key
  # and write it to the top level `pAmk[]` and `kMap[]` tables.
  db.vidAttach(HashLabel(root: root, key: expected), vid)
  ok()


proc leafToRootCrawler(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Hike for labelling leaf..root
      ): Result[DfReport,(VertexID,AristoError)] =
  ## Returns the index of the first node that could not be hashed by
  ## vertices all from the top layer cache.
  ##
  for n in (hike.legs.len-1).countDown(0):
    let
      wp = hike.legs[n].wp
      bg = hike.legs[n].backend
      node = wp.vtx.toNode(db, stopEarly=false, beKeyOk=false).valueOr:
        return ok DfReport(legInx: n, unresolved: error)

    # Vertices marked proof nodes need not be checked
    if wp.vid notin db.top.pPrf:

      # Check against existing key, or store new key
      let key = node.digestTo(HashKey)
      db.updateHashKey(hike.root, wp.vid, key, bg).isOkOr:
        return err((wp.vid,error))

  ok DfReport(legInx: -1) # all could be hashed


proc cloudConnect(
    cloud: HashSet[VertexID];          # Vertex IDs to start connecting from
    db: AristoDbRef;                   # Database, top layer
    target: BackVidTab;                # Vertices to arrive to
      ): tuple[paths: WidthFirstForest, unresolved: HashSet[VertexID]] =
  ## For each vertex ID from argument `cloud` find a chain of `FollowUpVid`
  ## type links reaching into argument `target`. The `paths` entry from the
  ## `result` tuple contains the connections to the `target` argument and the
  ## `unresolved` entries the IDs left over from `cloud`.
  if 0 < cloud.len:
    result.unresolved = cloud
    var hold = target
    while 0 < hold.len:
      # Greedily trace back `bottomUp[]` entries for finding parents of
      # unresolved vertices from `cloud`
      var redo: BackVidTab
      for (vid,val) in hold.pairs:
        let vtx = db.getVtx vid
        if vtx.isValid:
          result.paths.pool[vid] = val
          # Grab child links
          for sub in vtx.subVids:
            let w = FollowUpVid(
              root:  val.root,
              toVid: vid)
            if sub notin cloud:
              redo[sub] = w
            else:
              result.paths.base[sub] = w # ok, use this
              result.unresolved.excl sub
              if result.unresolved.len == 0:
                return
      redo.swap hold


proc updateWFF(
    wff: var WidthFirstForest;         # Search tree to update
    hike: Hike;                        # Chain of vertices
    ltr: DfReport;                     # Index and extra vertex IDs for `hike`
      ) =
  ## Use vertices from the `hike` argument and link them leaf-to-root in a way
  ## so so that they can be traversed later in a width-first search.
  ##
  ## The `ltr` argument augments the `hike` path in that it defines a set of
  ## extra vertices where the width-first search is supposed to start.
  ##
  ##                   ..unresolved hash keys | all set here..
  ##                                          |
  ## hike.legs: (leg[0], leg[1], ..leg[legInx], ..)
  ##               |       |         |
  ##               | <---- |  <----- |
  ##               |                 |
  ##               |   wff.pool[]    |
  ##
  ## and the set `unresolved{} × leg[legInx]` will be registered in `base[]`.
  ##
  # Root target to reach via width-first search
  wff.root.incl hike.root

  # Add unresolved nodes for top level links
  for u in 1 .. ltr.legInx:
    let vid = hike.legs[u].wp.vid
    # Make sure that `base[]` and `pool[]` are disjunkt, possibly moving
    # `base[]` entries to the `pool[]`.
    wff.base.del vid
    wff.pool[vid] = FollowUpVid(
      root:  hike.root,
      toVid: hike.legs[u-1].wp.vid)

  # These ones have been resolved, already
  for u in ltr.legInx+1 ..< hike.legs.len:
    let vid = hike.legs[u].wp.vid
    wff.pool.del vid
    wff.base.del vid

  assert 0 < ltr.unresolved.len # debugging, only
  let vid = hike.legs[ltr.legInx].wp.vid
  for sub in ltr.unresolved:
    # Update request for unresolved sub-links by adding a new tail
    # entry (unless registered, already.)
    if sub notin wff:
      wff.base[sub] = FollowUpVid(
        root:  hike.root,
        toVid: vid)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hashify*(
    db: AristoDbRef;                   # Database, top layer
      ): Result[HashSet[VertexID],(VertexID,AristoError)] =
  ## Add keys to the  `Patricia Trie` so that it becomes a `Merkle Patricia
  ## Tree`. If successful, the function returns the keys (aka Merkle hash) of
  ## the root vertices.
  var
    deleted = false                    # Need extra check for orphaned vertices
    completed: HashSet[VertexID]       # Root targets reached, already
    wff: WidthFirstForest              # Leaf-to-root traversal structure

  if not db.top.dirty:
    return ok completed

  for (lky,lfVid) in db.top.lTab.pairs:
    let
      rc = lky.hikeUp db
      hike = rc.to(Hike)

    if not lfVid.isValid:
      # Remember that there are left overs from a delete proedure which have
      # to be eventually found before starting width-first processing.
      deleted = true

    if hike.legs.len == 0:
      # Ignore left over path from deleted entry.
      if not lfVid.isValid:
        # FIXME: Is there a case for adding child-to-root links to the `wff`
        #        schedule?
        continue
      if rc.isErr:
        return err((lfVid,rc.error[1]))
      return err((hike.root,HashifyEmptyHike))

    # Hash as much of as possible from `hike` starting at the downmost `leg`
    let ltr = ? db.leafToRootCrawler hike

    if ltr.legInx < 0:
      completed.incl hike.root
    else:
      # Not all could be hashed, merge the rest into `wff` width-first schedule
      wff.updateWFF(hike, ltr)

  # Update unresolved keys left over after delete operations when overlay
  # vertices have been added and there was no `hike` path to capture them.
  #
  # Considering a list of updated paths to these vertices after deleting a
  # `Leaf` vertex is deemed too expensive and more error prone. So it is
  # the task to search for unresolved node keys and add glue paths them to
  # the depth-first schedule.
  if deleted:
    var unresolved: HashSet[VertexID]
    for (vid,lbl) in db.top.kMap.pairs:
      if not lbl.isValid and
         vid notin wff and
         (vid notin db.top.sTab or db.top.sTab.getOrVoid(vid).isValid):
        unresolved.incl vid

    let glue = unresolved.cloudConnect(db, wff.base)
    if 0 < glue.unresolved.len:
      return err((glue.unresolved.toSeq[0],HashifyNodeUnresolved))

    # Add glue items to `wff.base[]` and `wff.pool[]` tables
    for (vid,val) in glue.paths.base.pairs:
      # Add vid to `wff.base[]` list
      wff.base[vid] = val
      # Move tail of VertexID chain to `wff.pool[]`
      var toVid = val.toVid
      while true:
        let w = glue.paths.pool.getOrVoid toVid
        if not w.isValid:
          break
        wff.base.del toVid
        wff.pool[toVid] = w
        toVid = w.toVid

  # Traverse width-first schedule and update remaining hashes.
  while 0 < wff.base.len:
    var redo: BackVidTab
    for (vid,val) in wff.base.pairs:
      block thisVtx:
        let vtx = db.getVtx vid
        # Try to convert the vertex to a node. This is possible only if all
        # link references have Merkle hash keys, already.
        if not vtx.isValid:
          # This might happen when proof nodes (see `snap` protocol) are on
          # an incomplete trie where this `vid` has a key but no vertex yet.
          # Also, the key (as part of the proof data) must be on the backend
          # by the way `leafToRootCrawler()` works. So it is enough to verify
          # the key there.
          discard db.getKeyBE(vid).valueOr:
            return err((vid,HashifyNodeUnresolved))
          break thisVtx

        # Try to resolve the current vertex as node
        let node = vtx.toNode(db).valueOr:
          # Cannot complete with this vertex unless updated, so do it later.
          redo[vid] = val
          break thisVtx
        # End block `thisVtx`

        # Could resolve => update Merkle hash
        let key = node.digestTo(HashKey)
        db.vidAttach(HashLabel(root: val.root, key: key), vid)

      # Proceed with back link
      let nextVal = wff.pool.getOrVoid val.toVid
      if nextVal.isValid:
        # Make sure that we we keep strict hierachial order
        if nextVal.toVid in redo:
          # Push back from `redo[]` to be considered later
          wff.pool[nextVal.toVid] = redo.getOrVoid nextVal.toVid
          redo.del nextVal.toVid
          # And move the next one to `redo[]`
          wff.pool.del val.toVid
          redo[val.toVid] = nextVal
        elif val.toVid notin redo.values.toSeq.mapIt(it.toVid):
          wff.pool.del val.toVid
          redo[val.toVid] = nextVal

    # Restart `wff.base[]`
    wff.base.swap redo

  # Update root nodes
  for vid in wff.root - db.top.pPrf:
    # Convert root vertex to a node.
    let node = db.getVtx(vid).toNode(db,stopEarly=false).valueOr:
      return err((vid,HashifyRootNodeUnresolved))
    db.vidAttach(HashLabel(root: vid, key: node.digestTo(HashKey)), vid)
    completed.incl vid

  db.top.dirty = false
  ok completed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

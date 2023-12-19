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
  std/[sequtils, sets, tables],
  chronicles,
  eth/common,
  results,
  stew/byteutils,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_layers, aristo_serialise,
       aristo_utils]

type
  FollowUpVid = object
    ## Link item: VertexID -> VertexID
    root: VertexID                  ## Root vertex, might be void unless known
    toVid: VertexID                 ## Valid next/follow up vertex

  BackVidTab =
    Table[VertexID,FollowUpVid]

  WidthFirstForest = object
    ## Collected width first search trees
    completed: HashSet[VertexID]    ## Top level, root targets reached
    root: HashSet[VertexID]         ## Top level, root targets not reached yet
    pool: BackVidTab                ## Upper links pool
    base: BackVidTab                ## Width-first leaf level links

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
  vid in wff.base or vid in wff.pool or vid in wff.root or vid in wff.completed

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

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


proc setNextLink(
    wff: var WidthFirstForest;         # Search tree to update
    redo: var BackVidTab;              # Temporary `base` list
    val: FollowUpVid;                  # Current vertex value to follow up
      ) =
  ## Given the follow up argument `vid`, update the `redo[]` argument (an
  ## optional substitute for the `wff.base[]` list) so that the `redo[]`
  ## list contains the next `from->to` vertex pair from the `wff.pool[]`
  ## list.
  ##
  ## Unless the `redo` argument is passed as `wff.base`, this function
  ## supports the following construct:
  ## ::
  ##   while 0 < wff.base.len:
  ##     var redo: BackVidTab
  ##     for (vid,val) in wff.base.pairs:
  ##       ...
  ##       wff.setNextLink(redo, val)
  ##     wff.base.swap redo
  ##
  ## Otherwise, one would use the function as in
  ## ::
  ##   wff.base.del vid
  ##   wff.setNextLink(wff.pool, val)
  ##
  # Get current `from->to` vertex pair
  if val.isValid:
    # Find follow up `from->to` vertex pair in `pool`
    let nextVal = wff.pool.getOrVoid val.toVid
    if nextVal.isValid:

      # Make sure that strict hierachial order is kept. If the successor
      # is in the temporary `redo[]` base list, move it to the `pool[]`.
      if nextVal.toVid in redo:
        wff.pool[nextVal.toVid] = redo.getOrVoid nextVal.toVid
        redo.del nextVal.toVid

      elif val.toVid in redo.values.toSeq.mapIt(it.toVid):
        # The follow up vertex ID is already a follow up ID for some
        # `from->to` vertex pair in the temporary `redo[]` base list.
        return

      # Move next `from->to vertex`  pair to `redo[]`
      wff.pool.del val.toVid
      redo[val.toVid] = nextVal


proc updateSchedule(
    wff: var WidthFirstForest;         # Search tree to update
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Chain of vertices
      ) =
  ## Use vertices from the `hike` argument and link them leaf-to-root in a way
  ## so so that they can be traversed later in a width-first search.
  ##
  let
    root = hike.root
  var
    legInx = 0                 # find index of first unresolved vertex
    unresolved: seq[VertexID]  # vtx links, reason for unresolved vertex
  # Find the index `legInx` of the first vertex that could not be compiled as
  # node all from the top layer cache keys.
  block findlegInx:
    # Directly set leaf vertex key
    let
      leaf = hike.legs[^1].wp
      node = leaf.vtx.toNode(db, stopEarly=false, beKeyOk=false).valueOr:
        # Oops, depends on unresolved storage trie?
        legInx = hike.legs.len - 1
        unresolved = error
        break findlegInx
      vid = leaf.vid

    if not db.layersGetKeyOrVoid(vid).isValid:
      db.layersPutLabel(vid, HashLabel(root: root, key: node.digestTo(HashKey)))
      # Clean up unnecessay leaf node from previous session
      wff.base.del vid
      wff.setNextLink(wff.pool, wff.base.getOrVoid vid)

    # If possible, compute a node from the current vertex with all links
    # resolved on the cache layer. If this is not possible, stop here and
    # return the list of vertex IDs that could not be resolved (see option
    # `stopEarly=false`.)
    for n in (hike.legs.len-2).countDown(0):
      let vtx = hike.legs[n].wp.vtx
      discard vtx.toNode(db, stopEarly=false, beKeyOk=false).valueOr:
        legInx = n
        unresolved = error
        break findlegInx

    # All done this `hike`
    if db.layersGetKeyOrVoid(root).isValid:
      wff.root.excl root
    wff.completed.incl root
    return

  # Unresolved root target to reach via width-first search
  if root notin wff.completed:
    wff.root.incl root

  # Current situation:
  #
  #                 ..unresolved hash keys.. | ..all set here..
  #                                          |
  #                                          |
  # hike.legs: (leg[0], leg[1], ..leg[legInx], ..)
  #               |       |         | |
  #               | <---- |  <----- | +-------+----    \
  #               |                 |         |        |
  #               |   wff.pool[]    |         +----    | vertices from the
  #                                           :        | `unresoved` set
  #                                                    |
  #                                           +----    /

  # Add unresolved nodes for top level links
  for u in 1 .. legInx:
    let vid = hike.legs[u].wp.vid
    # Make sure that `base[]` and `pool[]` are disjunkt, possibly moving
    # `base[]` entries to the `pool[]`.
    wff.base.del vid
    wff.pool[vid] = FollowUpVid(
      root:  root,
      toVid: hike.legs[u-1].wp.vid)

  # These ones have been resolved, already
  for u in legInx+1 ..< hike.legs.len:
    let vid = hike.legs[u].wp.vid
    wff.pool.del vid
    wff.base.del vid

  assert 0 < unresolved.len # debugging, only
  let vid = hike.legs[legInx].wp.vid
  for sub in unresolved:
    # Update request for unresolved sub-links by adding a new tail
    # entry (unless registered, already.)
    if sub notin wff:
      wff.base[sub] = FollowUpVid(
        root:  root,
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
    wff: WidthFirstForest              # Leaf-to-root traversal structure

  if not db.dirty:
    return ok wff.completed

  for (lky,lfVid) in db.lTab.pairs:
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
        # FIXME: Is there a case for adding unresolved child-to-root links
        #        to the `wff` schedule?
        continue
      if rc.isErr:
        return err((lfVid,rc.error[1]))
      return err((hike.root,HashifyEmptyHike))

    # Compile width-first forest search schedule
    wff.updateSchedule(db, hike)

  if deleted:
    # Update unresolved keys left over after delete operations when overlay
    # vertices have been added and there was no `hike` path to capture them.
    #
    # Considering a list of updated paths to these vertices after deleting
    # a `Leaf` vertex is deemed too expensive and more error prone. So it
    # is the task to search for unresolved node keys and add glue paths to
    # the width-first schedule.
    var unresolved: HashSet[VertexID]
    for (vid,lbl) in db.layersWalkLabel:
      if not lbl.isValid and
         vid notin wff:
        let rc = db.layersGetVtx vid
        if rc.isErr or rc.value.isValid:
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

      let vtx = db.getVtx vid
      if not vtx.isValid:
        # This might happen when proof nodes (see `snap` protocol) are on
        # an incomplete trie where this `vid` has a key but no vertex yet.
        # Also, the key (as part of the proof data) must be on the backend
        # by the way `leafToRootCrawler()` works. So it is enough to verify
        # the key there.
        discard db.getKeyBE(vid).valueOr:
          return err((vid,HashifyNodeUnresolved))
      else:
        # Try to convert the vertex to a node. This is possible only if all
        # link references have Merkle hash keys, already.
        let node = vtx.toNode(db, stopEarly=false).valueOr:
          # Cannot complete this vertex unless its child node keys are compiled.
          # So do this vertex later, i.e. add the vertex to the `pool[]`.
          wff.pool[vid] = val
          # Add the child vertices to `redo[]` for the schedule `base[]` list.
          for w in error:
            if w notin wff.base and w notin redo:
              if db.layersGetVtx(w).isErr:
                # Ooops, should have been marked for update
                return err((w,HashifyNodeUnresolved))
              redo[w] = FollowUpVid(root: val.root, toVid: vid)
          continue # terminates error clause

        # Could resolve => update Merkle hash
        let key = node.digestTo(HashKey)
        db.layersPutLabel(vid, HashLabel(root: val.root, key: key))

        # Set follow up link for next round
        wff.setNextLink(redo, val)

    # Restart `wff.base[]`
    wff.base.swap redo

  # Update root nodes
  for vid in wff.root - db.pPrf:
    # Convert root vertex to a node.
    let node = db.getVtx(vid).toNode(db,stopEarly=false).valueOr:
      return err((vid,HashifyRootNodeUnresolved))
    db.layersPutLabel(vid, HashLabel(root: vid, key: node.digestTo(HashKey)))
    wff.completed.incl vid

  db.top.final.dirty = false
  db.top.final.lTab.clear
  ok wff.completed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

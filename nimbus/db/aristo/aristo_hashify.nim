# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
## are associated with the vertex IDs. Existing key associations are taken
## as-is/unchecked unless the ID is marked a proof node. In the latter case,
## the key is assumed to be correct after re-calculation.
##
## The labelling algorithm works roughly as follows:
##
## * Given a set of start or root vertices, build the forest (of trees)
##   downwards towards leafs vertices so that none of these vertices has a
##   Merkle hash label.
##
## * Starting at the leaf vertices in width-first fashion, calculate the
##   Merkle hashes and label the leaf vertices. Recursively work up labelling
##   vertices up until the root nodes are reached.
##
## Note that there are some tweaks for `proof` node vertices which lead to
## incomplete trees in a way that the algoritm handles existing Merkle hash
## labels for missing vertices.
##
{.push raises: [].}

import
  std/[algorithm, sequtils, sets, tables],
  chronicles,
  eth/common,
  results,
  stew/byteutils,
  "."/[aristo_desc, aristo_get, aristo_layers, aristo_serialise,
       aristo_utils, aristo_vid]

type
  WidthFirstForest = object
    ## Collected width first search trees
    root: HashSet[VertexID]                ## Top level, root targets
    pool: Table[VertexID,VertexID]         ## Upper links pool
    base: Table[VertexID,VertexID]         ## Width-first leaf level links
    leaf: HashSet[VertexID]                ## Stans-alone leaf to process
    rev: Table[VertexID,HashSet[VertexID]] ## Reverse look up table

logScope:
  topics = "aristo-hashify"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Hashify " & info

func getOrVoid(tab: Table[VertexID,VertexID]; vid: VertexID): VertexID =
  tab.getOrDefault(vid, VertexID(0))

func contains(wff: WidthFirstForest; vid: VertexID): bool =
  vid in wff.base or vid in wff.pool or vid in wff.root

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func hasValue(
    wffTable: Table[VertexID,VertexID];
    vid: VertexID;
    wff: WidthFirstForest;
      ): bool =
  ## Helper for efficient `value` access:
  ## ::
  ##   wffTable.hasValue(wff, vid)
  ##
  ## instead of
  ## ::
  ##   vid in wffTable.values.toSeq
  ##
  for w in wff.rev.getOrVoid vid:
    if w in wffTable:
      return true


proc pedigree(
    db: AristoDbRef;                   # Database, top layer
    ancestors: HashSet[VertexID];      # Vertex IDs to start connecting from
    proofs: HashSet[VertexID];         # Additional proof nodes to start from
      ): Result[WidthFirstForest,(VertexID,AristoError)] =
  ## For each vertex ID from the argument set `ancestors` find all un-labelled
  ## grand child vertices and build a forest (of trees) starting from the
  ## grand child vertices.
  ##
  var
    wff: WidthFirstForest
    leafs: HashSet[VertexID]

  proc register(wff: var WidthFirstForest; fromVid, toVid: VertexID) =
    if toVid in wff.base:
      # * there is `toVid->*` in `base[]`
      # * so ``toVid->*` moved to `pool[]`
      wff.pool[toVid] = wff.base.getOrVoid toVid
      wff.base.del toVid
    if wff.base.hasValue(fromVid, wff):
      # * there is `*->fromVid` in `base[]`
      # * so store `fromVid->toVid` in `pool[]`
      wff.pool[fromVid] = toVid
    else:
      # store  `fromVid->toVid` in `base[]`
      wff.base[fromVid] = toVid

    # Register reverse pair for quick table value lookup
    wff.rev.withValue(toVid, val):
      val[].incl fromVid
    do:
      wff.rev[toVid] = @[fromVid].toHashSet

    # Remove unnecessarey sup-trie roots (e.g. for a storage root)
    wff.root.excl fromVid

  # Initialise greedy search which will keep a set of current leafs in the
  # `leafs{}` set and follow up links in the `pool[]` table, leading all the
  # way up to the `root{}` set.
  #
  # Process root nodes if they are unlabelled
  var rootWasDeleted = VertexID(0)
  for root in ancestors:
    let vtx = db.getVtx root
    if vtx.isNil:
      if VertexID(LEAST_FREE_VID) <= root:
        # There must be a another root, as well (e.g. `$1` for a storage
        # root). Only the last one of some will be reported with error code.
        rootWasDeleted = root
    elif not db.getKey(root).isValid:
      # Need to process `root` node
      let children = vtx.subVids
      if children.len == 0:
        # This is an isolated leaf node
        wff.leaf.incl root
      else:
        wff.root.incl root
        for child in vtx.subVids:
          if not db.getKey(child).isValid:
            leafs.incl child
            wff.register(child, root)
  if rootWasDeleted.isValid and
     wff.root.len == 0 and
     wff.leaf.len == 0:
    return err((rootWasDeleted,HashifyRootVtxUnresolved))

  # Initialisation for `proof` nodes which are sort of similar to `root` nodes.
  for proof in proofs:
    let vtx = db.getVtx proof
    if vtx.isNil or not db.getKey(proof).isValid:
      return err((proof,HashifyVtxUnresolved))
    let children = vtx.subVids
    if 0 < children.len:
      # To be treated as a root node
      wff.root.incl proof
      for child in vtx.subVids:
        if not db.getKey(child).isValid:
          leafs.incl child
          wff.register(child, proof)

  # Recursively step down and collect unlabelled vertices
  while 0 < leafs.len:
    var redo: typeof(leafs)

    for parent in leafs:
      assert parent.isValid
      assert not db.getKey(parent).isValid

      let vtx = db.getVtx parent
      if not vtx.isNil:
        let children = vtx.subVids.filterIt(not db.getKey(it).isValid)
        if 0 < children.len:
          for child in children:
            redo.incl child
            wff.register(child, parent)
          continue

      if parent notin wff.base:
        # The buck stops here:
        #   move `(parent,granny)` from `pool[]` to `base[]`
        let granny = wff.pool.getOrVoid parent
        assert granny.isValid
        wff.register(parent, granny)
        wff.pool.del parent

    redo.swap leafs

  ok wff

# ------------------------------------------------------------------------------
# Private functions, tree traversal
# ------------------------------------------------------------------------------

proc createSched(
    db: AristoDbRef;                   # Database, top layer
      ): Result[WidthFirstForest,(VertexID,AristoError)] =
  ## Create width-first search schedule (aka forest)
  ##
  var wff = ? db.pedigree(db.dirty, db.pPrf)

  if 0 < wff.leaf.len:
    for vid in wff.leaf:
      let node = db.getVtx(vid).toNode(db, beKeyOk=false).valueOr:
        # Make sure that all those nodes are reachable
        for needed in error:
          if needed notin wff.base and
             needed notin wff.pool:
            return err((needed,HashifyVtxUnresolved))
        continue
      db.layersPutKey(VertexID(1), vid, node.digestTo(HashKey))

  ok wff


proc processSched(
    wff: var WidthFirstForest;         # Search tree to process
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Traverse width-first schedule and update vertex hash labels.
  ##
  while 0 < wff.base.len:
    var
      accept = false
      redo: typeof(wff.base)

    for (vid,toVid) in wff.base.pairs:
      let vtx = db.getVtx vid
      assert vtx.isValid

      # Try to convert the vertex to a node. This is possible only if all
      # link references have Merkle hash keys, already.
      let node = vtx.toNode(db, stopEarly=false).valueOr:
        # Do this vertex later, again
        if wff.pool.hasValue(vid, wff):
          wff.pool[vid] = toVid
          accept = true # `redo[]` will be fifferent from `base[]`
        else:
          redo[vid] = toVid
        continue
        # End `valueOr` terminates error clause

      # Could resolve => update Merkle hash
      db.layersPutKey(VertexID(1), vid, node.digestTo HashKey)

      # Set follow up link for next round
      let toToVid = wff.pool.getOrVoid toVid
      if toToVid.isValid:
        if toToVid in redo:
          # Got predecessor `(toVid,toToVid)` of `(toToVid,xxx)`,
          # so move `(toToVid,xxx)` from `redo[]` to `pool[]`
          wff.pool[toToVid] = redo.getOrVoid toToVid
          redo.del toToVid
        # Move `(toVid,toToVid)` from `pool[]` to `redo[]`
        wff.pool.del toVid
        redo[toVid] = toToVid

      accept = true # `redo[]` will be fifferent from `base[]`
      # End `for (vid,toVid)..`

    # Make sure that `base[]` is different from `redo[]`
    if not accept:
      let vid = wff.base.keys.toSeq[0]
      return err((vid,HashifyVtxUnresolved))
    # Restart `wff.base[]`
    wff.base.swap redo

  ok()


proc finaliseRoots(
    wff: var WidthFirstForest;         # Search tree to process
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Process root vertices after all other vertices are done.
  ##
  # Make sure that the pool has been exhausted
  if 0 < wff.pool.len:
    let vid = wff.pool.keys.toSeq.sorted[0]
    return err((vid,HashifyVtxUnresolved))

  # Update or verify root nodes
  for vid in wff.root:
    # Calculate hash key
    let
      node = db.getVtx(vid).toNode(db).valueOr:
        return err((vid,HashifyRootVtxUnresolved))
      key = node.digestTo(HashKey)
    if vid notin db.pPrf:
      db.layersPutKey(VertexID(1), vid, key)
    elif key != db.getKey vid:
      return err((vid,HashifyProofHashMismatch))

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hashify*(
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Add keys to the  `Patricia Trie` so that it becomes a `Merkle Patricia
  ## Tree`. If successful, the function returns the keys (aka Merkle hash) of
  ## the root vertices.
  ##
  if 0 < db.dirty.len:
    # Set up widh-first traversal schedule
    var wff = ? db.createSched()

    # Traverse tree spanned by `wff` and label remaining vertices.
    ? wff.processSched db

    # Do/complete state root vertices
    ? wff.finaliseRoots db

    db.top.final.dirty.clear               # Mark top layer clean
    db.top.final.vGen = db.vGen.vidReorg() # Squeze list of recycled vertex IDs

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

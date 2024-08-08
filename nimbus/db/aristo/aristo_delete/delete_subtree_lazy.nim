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
  std/sets,
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get, aristo_layers],
  ./delete_helpers

const
  extraDebuggingMessages = false # or true
    ## Enable additional logging noise. Note that this might slow down the
    ## system performance but will not be too significant. When importing the
    ## first 5m blocks from `era1` on some Debian system,
    ## * loading time was ~5h
    ## * overhead of accumulated analysis times was ~1.2s

type
  VidCollect = tuple
    data: array[DELETE_SUBTREE_VERTICES_MAX,VertexID]
    top: int                         # Next free slot if smaller `.data.len`


when extraDebuggingMessages:
  import
    std/times,
    chronicles,
    ./delete_debug

  const
    allStatsFrequency = 20
      ## Print accumutated statistics every `allStatsFrequency` visits of
      ## the analysis tool.

    minVtxsForLogging = 1000
      ## Suppress detailed logging for smaller sub-trees

  var stats: SubTreeStatsAccu
    ## Accumulated statistics

  func `$`(ela: Duration): string =
    ela.toStr

  template debugLog(info: static[string]; args: varargs[untyped]) =
    ## Statistics message via `chronicles` logger, makes it easy to
    ## change priority and format.
    notice info, args

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

func capa(T: type VidCollect): int =
  ## Syntactic sugar
  T.default.data.len


proc collectSubTreeLazily(
  db: AristoDbRef;                     # Database, top layer
  rvid: RootedVertexID;                # Root vertex
  vids: var VidCollect;                # Accumulating vertex IDs for deletion
    ): Result[void,AristoError]  =
  ## Collect vids for a small sub-tree
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  if vids.top < vids.data.len:
    vids.data[vids.top] = rvid.vid
    vids.top.inc                       # Max value of `.top`: `vid.data.len + 1`

    if vtx.vType == Branch:
      for n in 0..15:
        if vtx.bVid[n].isValid:
          ? db.collectSubTreeLazily((rvid.root,vtx.bVid[n]), vids)

  elif vids.top <= vids.data.len:
    vids.top.inc                       # Terminates here

  ok()


proc collectStoTreeLazily(
  db: AristoDbRef;                     # Database, top layer
  rvid: RootedVertexID;                # Root vertex
  accPath: Hash256;                    # Accounts cache designator
  stoPath: NibblesBuf;                 # Current storage path
  vids: var VidCollect;                # Accumulating vertex IDs for deletion
    ): Result[void,AristoError] =
  ## Collect vertex/vid and delete cache entries.
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  case vtx.vType
  of Branch:
    for i in 0..15:
      if vtx.bVid[i].isValid:
        ? db.collectStoTreeLazily(
          (rvid.root, vtx.bVid[i]), accPath,
          stoPath & vtx.ePfx & NibblesBuf.nibble(byte i),
          vids)

  of Leaf:
    let stoPath = Hash256(data: (stoPath & vtx.lPfx).getBytes())
    db.layersPutStoLeaf(AccountKey.mixUp(accPath, stoPath), nil)

  # There is no useful approach avoiding to walk the whole tree for updating
  # the storage data access cache.
  #
  # The alternative of stopping here and clearing the whole cache did degrade
  # performance significantly in some tests on mainnet when importing `era1`.
  #
  # When not clearing the cache it was seen
  # * filled up to maximum size most of the time
  # * at the same time having no `stoPath` hit at all (so there was nothing
  #   to be cleared.)
  #
  if vids.top <= vids.data.len:
    if vids.top < vids.data.len:
      vids.data[vids.top] = rvid.vid
    vids.top.inc                       # Max value of `.top`: `vid.data.len + 1`

  ok()


proc disposeOfSubTree(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
    vids: var VidCollect;              # Accumulated vertex IDs for disposal
      ) =
  ## Evaluate results from `collectSubTreeLazyImpl()` or ftom
  ## `collectStoTreeLazyImpl)`.
  ##
  if vids.top <= typeof(vids).capa:
    # Delete small tree
    for n in 0 ..< vids.top:
      db.disposeOfVtx((rvid.root, vids.data[n]))

  else:
    # Mark the sub-trees disabled to be deleted not until the layer is
    # finally stored onto the backend.
    let vtx = db.getVtxRc(rvid).value[0]
    for n in 0..15:
      if vtx.bVid[n].isValid:
        db.top.delTree.add (rvid.root,vtx.bVid[n])

    # Delete top of tree now.
    db.disposeOfVtx(rvid)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc delSubTreeImpl*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # Root vertex
      ): Result[void,AristoError] =
  ## Delete all the `subRoots`if there are a few, only. Otherwise
  ## mark it for deleting later.
  discard db.getVtxRc((root,root)).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  when extraDebuggingMessages:
    let
      ana = db.analyseSubTree((root,root), VidCollect.capa+1, stats)
      start = getTime()

  var dispose: VidCollect
  ? db.collectSubTreeLazily((root,root), dispose)

  db.disposeOfSubTree((root,root), dispose)

  when extraDebuggingMessages:
    if typeof(dispose).capa < dispose.top:

      if minVtxsForLogging < ana.nVtxs:
        debugLog("Generic sub-tree analysis",
          nVtxs      = ana.nVtxs,
          nLeafs     = ana.nLeafs,
          depthMax   = ana.depthMax,
          nDelTree   = db.top.delTree.len,
          elaCollect = getTime() - start)

      if (stats.count mod allStatsFrequency) == 0:
        let
          start = getTime()
          (count, vtxs, leafs, depth, elapsed) = stats.strStats
        debugLog("Sub-tree analysis stats", count, vtxs, leafs, depth, elapsed)
        stats.sElapsed += getTime() - start
  ok()


proc delStoTreeImpl*(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
    accPath: Hash256;
      ): Result[void,AristoError] =
  ## Collect vertex/vid and cache entry.
  discard db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  when extraDebuggingMessages:
    let
      ana = db.analyseSubTree(rvid, VidCollect.capa+1, stats)
      start = getTime()

  var dispose: VidCollect              # Accumulating vertices for deletion
  ? db.collectStoTreeLazily(rvid, accPath, NibblesBuf(), dispose)

  db.disposeOfSubTree(rvid, dispose)

  when extraDebuggingMessages:
    if typeof(dispose).capa < dispose.top:

      if minVtxsForLogging < ana.nVtxs or db.stoLeaves.len < ana.nStoCache:
        debugLog("Storage sub-tree analysis",
          nVtxs          = ana.nVtxs,
          nLeafs         = ana.nLeafs,
          depthMax       = ana.depthMax,
          nStoCache      = ana.nStoCache,
          nStoCacheDelta = ana.nStoCache - db.stoLeaves.len,
          nDelTree       = db.top.delTree.len,
          elaCollect     = getTime() - start)

      if (stats.count mod allStatsFrequency) == 0:
        let
          start = getTime()
          (count, vtxs, leafs, depth, elapsed) = stats.strStats
        debugLog("Sub-tree analysis stats", count, vtxs, leafs, depth, elapsed)
        stats.sElapsed += getTime() - start
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

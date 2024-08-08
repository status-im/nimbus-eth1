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
  std/[math, strformat, times],
  chronicles,
  ".."/[aristo_desc, aristo_get, aristo_profile]

export
  aristo_profile.toStr

type
  SubTreeStats* = tuple
    nVtxs: int                         ## Number of vertices in sub-tree
    nLeafs: int                        ## Number of leafs in sub-tree
    depthMax: int                      ## Maximal vertex path length
    nStoCache: int                     ## Size of storage leafs cache
    elapsed: Duration                  ## Time spent analysing

  SubTreeStatsAccu* = tuple
    count: int                         ## Number of entries
    sVtxs, qVtxs: float                ## Sum and square sum of `.nVtxs`
    sLeafs, qLeafs: float              ## Sum and square sum of `.nLeafs`
    sDepth, qDepth: float              ## Sum and square sum of `.depthMax`
    sElapsed: Duration                 ## Sum of `.elapsed`

  SubTreeDist* = tuple
    count: int                         ## Number of entries
    mVtxs, dVtxs: float                ## Mean and std deviation of `.nVtxs`
    mLeafs, dLeafs: float              ## Mean and std deviation of `.nLeafs`
    mDepth, dDepth: float              ## Mean and std deviation of `.depthMax`

# ------------------------------------------------------------------------------
# Prival helper
# ------------------------------------------------------------------------------

proc analyseSubTreeImpl(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
    depth: int;                        # Recursion depth
    stats: var SubTreeStats;           # Statistics
      ) =
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    return

  stats.nVtxs.inc

  if stats.depthMax < depth:
    stats.depthMax = depth

  case vtx.vType:
  of Branch:
    for n in 0..15:
      if vtx.bVid[n].isValid:
        db.analyseSubTreeImpl((rvid.root,vtx.bVid[n]), depth+1, stats)
  of Leaf:
    stats.nLeafs.inc


func evalDist(count: int; sum, sqSum: float): tuple[mean, stdDev: float] =
  result.mean = sum / count.float

  let
    sqMean = sqSum / count.float
    meanSq = result.mean * result.mean

    # Mathematically, `meanSq <= sqMean` but there might be rounding errors
    # if `meanSq` and `sqMean` are approximately the same.
    sigma = sqMean - min(meanSq,sqMean)
    
  result.stdDev = sigma.sqrt

# ------------------------------------------------------------------------------
# Public analysis tools
# ------------------------------------------------------------------------------

proc analyseSubTree*(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
    minVtxs: int;                      # Accumulate if `minVtxs` <= `.nVtxs`
    accu: var SubTreeStatsAccu;        # For accumulated statistics
      ): SubTreeStats =
  let start = getTime()
  db.analyseSubTreeImpl(rvid, 1, result)
  result.nStoCache = db.stoLeaves.len

  if minVtxs <= result.nVtxs:
    accu.count.inc
    accu.sVtxs += result.nVtxs.float
    accu.qVtxs += (result.nVtxs * result.nVtxs).float
    accu.sLeafs += result.nLeafs.float
    accu.qLeafs += (result.nLeafs * result.nLeafs).float
    accu.sDepth += result.depthMax.float
    accu.qDepth += (result.depthMax * result.depthMax).float

  result.elapsed = getTime() - start
  accu.sElapsed += result.elapsed      # Unconditionally collecrd


func stats*(a: SubTreeStatsAccu): SubTreeDist =
  result.count = a.count
  (result.mVtxs, result.dVtxs) = evalDist(a.count, a.sVtxs, a.qVtxs)
  (result.mLeafs, result.dLeafs) = evalDist(a.count, a.sLeafs, a.qLeafs)
  (result.mDepth, result.dDepth) = evalDist(a.count, a.sDepth, a.qDepth)

func strStats*(
    a: SubTreeStatsAccu;
      ): tuple[count, vtxs, leafs, depth, elapsed: string] =
  let w = a.stats()
  result.count = $w.count
  result.elapsed = a.sElapsed.toStr
  result.vtxs = &"{w.mVtxs:.1f}[{w.dVtxs:.1f}]"
  result.leafs = &"{w.mLeafs:.1f}[{w.dLeafs:.1f}]"
  result.depth = &"{w.mDepth:.1f}[{w.dDepth:.1f}]"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

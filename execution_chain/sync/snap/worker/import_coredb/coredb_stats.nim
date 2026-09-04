# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Not for production, at all.
## ---------------------------
##
{.push raises: [].}

import
  pkg/[chronicles, chronos],
  ../../../../db/aristo/aristo_init/rocks_db,
  ../../../../db/aristo/[aristo_compute, aristo_desc, aristo_get],
  ../worker_desc,
  ./coredb_desc

logScope:
  topics = "snap sync"

type
  Db2StatsWalk* = tuple
    accLeaf: uint
    accCode: uint
    stoTrie: uint
    stoLeaf: uint
    ela: Duration

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc travCoreDb2StatsImpl(
    tx2: CoreDbTxRef;
    base: Hash32;
    rvid: RootedVertexID;
    path: NibblesBuf;
    stats: var Db2StatsWalk;
    depth: int;
      ): Opt[void] =
  const
    info = "travCoreDb2StatsImpl"

  let (vtx,_) = tx2.aTx.getVtxRc(rvid).valueOr:
    error info & ": Fetching vertex failed", rvid, path, depth
    return err()

  doAssert depth <= 128
  case vtx.vType:
  of AccLeaf:
    let vtx = AccLeafRef(vtx)
    doAssert path.len + vtx.pfx.len == 64
    stats.accLeaf.inc

    # Contract code if there is any
    if vtx.account.codeHash != EMPTY_CODE_HASH:
      stats.accCode.inc

    # Handle storage slts sub-MPT
    if vtx.stoID.isValid:
      stats.stoTrie.inc

      # Descend into strorage sub-MPT
      let stoRvtx = (vtx.stoID.vid, vtx.stoID.vid)
      tx2.travCoreDb2StatsImpl(
            Hash32.fromBytes (path & vtx.pfx).getBytes(),
            stoRvtx, NibblesBuf(), stats, depth+1).isOkOr:
        return err()

  of StoLeaf:
    let vtx = StoLeafRef(vtx)
    doAssert path.len + vtx.pfx.len == 64
    stats.stoLeaf.inc

  of Branches:
    doAssert path.len + vtx.pfx.len <= 64
    let path = path & vtx.pfx
    for n,vid in vtx.pairs():
      let
        subRvid = (rvid.root,vid)
        path = path & NibblesBuf.nibble(n)
      tx2.travCoreDb2StatsImpl(base, subRvid, path, stats, depth+1).isOkOr:
        return err()

  of BoundaryNode:
    discard

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc statsTraverse*(db2: CoreDb2Ref): Opt[Db2StatsWalk] =
  ## ..
  let start = Moment.now()
  var stats: Db2StatsWalk

  const rvid = (STATE_ROOT_VID,STATE_ROOT_VID)
  ?db2.tx2.travCoreDb2StatsImpl(zeroHash32, rvid, NibblesBuf(), stats, 0)

  stats.ela = Moment.now() - start
  ok(stats)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

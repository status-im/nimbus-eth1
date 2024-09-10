# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/eth/p2p,
  pkg/results,
  pkg/stew/interval_set,
  ../worker_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc unprocFetch*(ctx: FlareCtxRef; maxLen: uint64): Result[BnRange,void] =
  ## Fetch interval from block ranges with maximal size `maxLen`, where
  ## `0` is interpreted as `2^64`.
  ##
  let
    q = ctx.lhc.unprocessed

    # Fetch top right interval with largest block numbers
    jv = q.le().valueOr:
      return err()

    # Curb interval to maximal length `maxLen`
    iv = block:
      if maxLen == 0 or (0 < jv.len and jv.len <= maxLen):
        jv
      else:
        # Curb interval `jv` to length `maxLen`
        #
        # Note that either (fringe case):
        #   (`jv.len`==0)  => (`jv`==`[0,high(u64)]`) => `jv.maxPt`==`high(u64)`
        # or (in the non-fringe case)
        #   (`maxLen` < `jv.len`) => (`jv.maxPt` - `maxLen` + 1 <= `jv.maxPt`)
        #
        BnRange.new(jv.maxPt - maxLen + 1, jv.maxPt)

  discard q.reduce(iv)
  ok(iv)

proc unprocMerge*(ctx: FlareCtxRef; iv: BnRange) =
  ## Merge back unprocessed range
  discard ctx.lhc.unprocessed.merge(iv)

proc unprocMerge*(ctx: FlareCtxRef; minPt, maxPt: BlockNumber) =
  ## Ditto
  discard ctx.lhc.unprocessed.merge(minPt, maxPt)


proc unprocReduce*(ctx: FlareCtxRef; minPt, maxPt: BlockNumber) =
  ## Merge back unprocessed range
  discard ctx.lhc.unprocessed.reduce(minPt, maxPt)


proc unprocFullyCovered*(
    ctx: FlareCtxRef; minPt, maxPt: BlockNumber): bool =
  ## Check whether range is fully contained
  ctx.lhc.unprocessed.covered(minPt, maxPt) == maxPt - minPt + 1

proc unprocCovered*(ctx: FlareCtxRef; minPt, maxPt: BlockNumber): uint64 =
  ## Check whether range is fully contained
  ctx.lhc.unprocessed.covered(minPt, maxPt)

proc unprocCovered*(ctx: FlareCtxRef; pt: BlockNumber): bool =
  ## Check whether point is contained
  ctx.lhc.unprocessed.covered(pt, pt) == 1


proc unprocClear*(ctx: FlareCtxRef) =
  ctx.lhc.unprocessed.clear()


proc unprocTop*(ctx: FlareCtxRef): BlockNumber =
  let iv = ctx.lhc.unprocessed.le().valueOr:
    return BlockNumber(0)
  iv.maxPt

proc unprocTotal*(ctx: FlareCtxRef): uint64 =
  ctx.lhc.unprocessed.total()

proc unprocChunks*(ctx: FlareCtxRef): int =
  ctx.lhc.unprocessed.chunks()

# ------------

proc unprocInit*(ctx: FlareCtxRef) =
  ## Constructor
  ctx.lhc.unprocessed = BnRangeSet.init()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

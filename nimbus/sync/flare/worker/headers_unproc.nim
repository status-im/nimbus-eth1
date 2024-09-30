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

proc headersUnprocFetch*(
    ctx: FlareCtxRef;
    maxLen: uint64;
      ): Result[BnRange,void] =
  ## Fetch interval from block ranges with maximal size `maxLen`, where
  ## `0` is interpreted as `2^64`.
  ##
  let
    q = ctx.lhc.unprocessed

    # Fetch top/right interval with largest block numbers
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
        #   (`maxLen` < `jv.len`) => (`jv.maxPt` - `maxLen` + 1 < `jv.maxPt`)
        #
        BnRange.new(jv.maxPt - maxLen + 1, jv.maxPt)

  discard q.reduce(iv)
  ctx.lhc.borrowed += iv.len
  ok(iv)


proc headersUnprocCommit*(ctx: FlareCtxRef; borrowed: uint) =
  ## Commit back all processed range
  ctx.lhc.borrowed -= borrowed

proc headersUnprocCommit*(ctx: FlareCtxRef; borrowed: uint; retuor: BnRange) =
  ## Merge back unprocessed range `retour`
  ctx.headersUnprocCommit borrowed
  doAssert ctx.lhc.unprocessed.merge(retuor) == retuor.len

proc headersUnprocCommit*(
    ctx: FlareCtxRef;
    borrowed: uint;
    rMinPt: BlockNumber;
    rMaxPt: BlockNumber) =
  ## Variant of `headersUnprocCommit()`
  ctx.headersUnprocCommit borrowed
  doAssert ctx.lhc.unprocessed.merge(rMinPt, rMaxPt) == rMaxPt - rMinPt + 1



proc headersUnprocCovered*(ctx: FlareCtxRef; minPt,maxPt: BlockNumber): uint64 =
  ## Check whether range is fully contained
  ctx.lhc.unprocessed.covered(minPt, maxPt)

proc headersUnprocCovered*(ctx: FlareCtxRef; pt: BlockNumber): bool =
  ## Check whether point is contained
  ctx.lhc.unprocessed.covered(pt, pt) == 1


proc headersUnprocTop*(ctx: FlareCtxRef): BlockNumber =
  let iv = ctx.lhc.unprocessed.le().valueOr:
    return BlockNumber(0)
  iv.maxPt

proc headersUnprocTotal*(ctx: FlareCtxRef): uint64 =
  ctx.lhc.unprocessed.total()

proc headersUnprocBorrowed*(ctx: FlareCtxRef): uint64 =
  ctx.lhc.borrowed

proc headersUnprocChunks*(ctx: FlareCtxRef): int =
  ctx.lhc.unprocessed.chunks()

proc headersUnprocIsEmpty*(ctx: FlareCtxRef): bool =
  ctx.lhc.unprocessed.chunks() == 0

# ------------

proc headersUnprocInit*(ctx: FlareCtxRef) =
  ## Constructor
  ctx.lhc.unprocessed = BnRangeSet.init()


proc headersUnprocSet*(ctx: FlareCtxRef) =
  ## Clear
  ctx.lhc.unprocessed.clear()
  ctx.lhc.borrowed = 0u

proc headersUnprocSet*(ctx: FlareCtxRef; iv: BnRange) =
  ## Set up new unprocessed range
  ctx.headersUnprocSet()
  discard ctx.lhc.unprocessed.merge(iv)

proc headersUnprocSet*(ctx: FlareCtxRef; minPt, maxPt: BlockNumber) =
  ## Set up new unprocessed range
  ctx.headersUnprocSet()
  discard ctx.lhc.unprocessed.merge(minPt, maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

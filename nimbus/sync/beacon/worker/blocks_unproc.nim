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
  pkg/eth/[common, p2p],
  pkg/results,
  pkg/stew/interval_set,
  ../worker_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blocksUnprocFetch*(
    ctx: BeaconCtxRef;
    maxLen: uint64;
      ): Result[BnRange,void] =
  ## Fetch interval from block ranges with maximal size `maxLen`, where
  ## `0` is interpreted as `2^64`.
  ##
  let
    q = ctx.blk.unprocessed

    # Fetch bottom/left interval with least block numbers
    jv = q.ge().valueOr:
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
        #   (`maxLen` < `jv.len`) => (`jv.minPt` + `maxLen` - 1 < `jv.maxPt`)
        #
        BnRange.new(jv.minPt, jv.minPt + maxLen - 1)

  discard q.reduce(iv)
  ctx.blk.borrowed += iv.len
  ok(iv)


proc blocksUnprocCommit*(ctx: BeaconCtxRef; borrowed: uint) =
  ## Commit back all processed range
  ctx.blk.borrowed -= borrowed

proc blocksUnprocCommit*(ctx: BeaconCtxRef; borrowed: uint; retuor: BnRange) =
  ## Merge back unprocessed range `retour`
  ctx.blocksUnprocCommit borrowed
  doAssert ctx.blk.unprocessed.merge(retuor) == retuor.len

proc blocksUnprocCommit*(
    ctx: BeaconCtxRef;
    borrowed: uint;
    rMinPt: BlockNumber;
    rMaxPt: BlockNumber) =
  ## Variant of `blocksUnprocCommit()`
  ctx.blocksUnprocCommit borrowed
  doAssert ctx.blk.unprocessed.merge(rMinPt, rMaxPt) == rMaxPt - rMinPt + 1


proc blocksUnprocCovered*(ctx: BeaconCtxRef; minPt,maxPt: BlockNumber): uint64 =
  ## Check whether range is fully contained
  # Argument `maxPt` would be internally adjusted to `max(minPt,maxPt)`
  if minPt <= maxPt:
    return ctx.blk.unprocessed.covered(minPt, maxPt)

proc blocksUnprocCovered*(ctx: BeaconCtxRef; pt: BlockNumber): bool =
  ## Check whether point is contained
  ctx.blk.unprocessed.covered(pt, pt) == 1


proc blocksUnprocTop*(ctx: BeaconCtxRef): BlockNumber =
  let iv = ctx.blk.unprocessed.le().valueOr:
    return BlockNumber(0)
  iv.maxPt

proc blocksUnprocBottom*(ctx: BeaconCtxRef): BlockNumber =
  let iv = ctx.blk.unprocessed.ge().valueOr:
    return high(BlockNumber)
  iv.minPt


proc blocksUnprocTotal*(ctx: BeaconCtxRef): uint64 =
  ctx.blk.unprocessed.total()

proc blocksUnprocBorrowed*(ctx: BeaconCtxRef): uint64 =
  ctx.blk.borrowed

proc blocksUnprocChunks*(ctx: BeaconCtxRef): int =
  ctx.blk.unprocessed.chunks()

proc blocksUnprocIsEmpty*(ctx: BeaconCtxRef): bool =
  ctx.blk.unprocessed.chunks() == 0

# ------------------

proc blocksUnprocInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.blk.unprocessed = BnRangeSet.init()

proc blocksUnprocClear*(ctx: BeaconCtxRef) =
  ## Clear
  ctx.blk.unprocessed.clear()
  ctx.blk.borrowed = 0u

proc blocksUnprocSet*(ctx: BeaconCtxRef; minPt, maxPt: BlockNumber) =
  ## Set up new unprocessed range
  ctx.blocksUnprocClear()
  # Argument `maxPt` would be internally adjusted to `max(minPt,maxPt)`
  if minPt <= maxPt:
    discard ctx.blk.unprocessed.merge(minPt, maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  doAssert ctx.blk.borrowed.merge(iv) == iv.len
  ok(iv)


proc blocksUnprocCommit*(ctx: BeaconCtxRef; iv: BnRange) =
  ## Commit back all processed range, i.e. remove it from the borrowed set.
  doAssert ctx.blk.borrowed.reduce(iv) == iv.len

proc blocksUnprocCommit*(ctx: BeaconCtxRef; iv, unproc: BnRange) =
  ## Variant of `blocksUnprocCommit()` which merges back some unprocessed
  ## range `unproc`.
  doAssert ctx.blk.borrowed.reduce(iv) == iv.len
  doAssert ctx.blk.unprocessed.merge(unproc) == unproc.len

proc blocksUnprocCommit*(
    ctx: BeaconCtxRef;
    iv: BnRange;
    uMinPt: BlockNumber;
    uMaxPt: BlockNumber;
      ) =
  ## Variant of `blocksUnprocCommit()`which merges back some unprocessed
  ## range `[uMinPt,uMaxPt]`.
  doAssert ctx.blk.borrowed.reduce(iv) == iv.len
  if uMinPt <= uMaxPt:
    # Otherwise `maxPt` would be internally adjusted to `max(minPt,maxPt)`
    doAssert ctx.blk.unprocessed.merge(uMinPt, uMaxPt) == uMaxPt - uMinPt + 1


proc blocksUnprocAppend*(ctx: BeaconCtxRef; minPt, maxPt: uint64) =
  ## Add some unprocessed range while leaving the borrowed queue untouched.
  ## The argument range will be curbed by existing `borrowed` entries (so
  ## it might become a set of ranges.)
  # Argument `maxPt` would be internally adjusted to `max(minPt,maxPt)`
  if minPt <= maxPt:
    if 0 < ctx.blk.borrowed.covered(minPt, maxPt):
      # Must Reduce by currenty borrowed block numbers
      for pt in minPt .. maxPt:
        # So this is piecmeal adding to unprocessed numbers
        if ctx.blk.borrowed.covered(pt,pt) == 0:
          discard ctx.blk.unprocessed.merge(pt, pt)
    else:
      discard ctx.blk.unprocessed.merge(minPt, maxPt)


proc blocksUnprocAvail*(ctx: BeaconCtxRef): uint64 =
  ## Returns the number of blocks that can be fetched
  ctx.blk.unprocessed.total()

proc blocksUnprocAvailBottom*(ctx: BeaconCtxRef): uint64 =
  ## Returns the least number from the `unprocessed` ranges set. It
  ## will default to `high(uint64)` if the range set is empty.
  let iv = ctx.blk.unprocessed.ge().valueOr:
    return high(uint64)
  iv.minPt


proc blocksUnprocTotal*(ctx: BeaconCtxRef): uint64 =
  ## Returns the sum of `borrowed` and `unprocessed` ranges.
  ctx.blk.unprocessed.total() + ctx.blk.borrowed.total()

proc blocksUnprocTotalBottom*(ctx: BeaconCtxRef): uint64 =
  ## Returns the number item from `borrowed` and `unprocessed` ranges. It
  ## will return `high(uint64)` if both range sets are empty.
  let
    uMin = block:
      let rc = ctx.blk.unprocessed.ge(0)
      if rc.isOk:
        rc.value.minPt
      else:
        high(BlockNumber)
    bMin = block:
      let rc = ctx.blk.borrowed.ge(0)
      if rc.isOk:
        rc.value.minPt
      else:
        high(BlockNumber)
  min(uMin, bMin)


proc blocksUnprocIsEmpty*(ctx: BeaconCtxRef): bool =
  ## True iff there are neither `borrowed` or `unprocessed` entries.
  ctx.blk.unprocessed.chunks() == 0 and
  ctx.blk.borrowed.chunks() == 0

# ------------------

proc blocksUnprocInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.blk.unprocessed = BnRangeSet.init()
  ctx.blk.borrowed = BnRangeSet.init()

proc blocksUnprocClear*(ctx: BeaconCtxRef) =
  ## Clear
  ctx.blk.unprocessed.clear()
  ctx.blk.borrowed.clear()

proc blocksUnprocSet*(ctx: BeaconCtxRef; minPt, maxPt: uint64) =
  ## Set up new unprocessed range
  ctx.blocksUnprocClear()
  if minPt <= maxPt:
    # Otherwise `maxPt` would be internally adjusted to `max(minPt,maxPt)`
    discard ctx.blk.unprocessed.merge(minPt, maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

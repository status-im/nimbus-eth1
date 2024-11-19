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

proc headersUnprocFetch*(
    ctx: BeaconCtxRef;
    maxLen: uint64;
      ): Result[BnRange,void] =
  ## Fetch interval from block ranges with maximal size `maxLen`, where
  ## `0` is interpreted as `2^64`.
  ##
  let
    q = ctx.hdr.unprocessed

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
  ctx.hdr.borrowed += iv.len
  ok(iv)


proc headersUnprocCommit*(ctx: BeaconCtxRef; borrowed: uint) =
  ## Commit back all processed range
  ctx.hdr.borrowed -= borrowed

proc headersUnprocCommit*(ctx: BeaconCtxRef; borrowed: uint; retuor: BnRange) =
  ## Merge back unprocessed range `retour`
  ctx.headersUnprocCommit borrowed
  doAssert ctx.hdr.unprocessed.merge(retuor) == retuor.len

proc headersUnprocCommit*(
    ctx: BeaconCtxRef;
    borrowed: uint;
    rMinPt: BlockNumber;
    rMaxPt: BlockNumber) =
  ## Variant of `headersUnprocCommit()`
  ctx.headersUnprocCommit borrowed
  doAssert ctx.hdr.unprocessed.merge(rMinPt, rMaxPt) == rMaxPt - rMinPt + 1



proc headersUnprocCovered*(
    ctx: BeaconCtxRef;
    minPt: BlockNumber;
    maxPt: BlockNumber;
      ): uint64 =
  ## Check whether range is fully contained
  # Argument `maxPt` would be internally adjusted to `max(minPt,maxPt)`
  if minPt <= maxPt:
    return ctx.hdr.unprocessed.covered(minPt, maxPt)

proc headersUnprocCovered*(ctx: BeaconCtxRef; pt: BlockNumber): bool =
  ## Check whether point is contained
  ctx.hdr.unprocessed.covered(pt, pt) == 1


proc headersUnprocTop*(ctx: BeaconCtxRef): BlockNumber =
  let iv = ctx.hdr.unprocessed.le().valueOr:
    return BlockNumber(0)
  iv.maxPt

proc headersUnprocTotal*(ctx: BeaconCtxRef): uint64 =
  ctx.hdr.unprocessed.total()

proc headersUnprocBorrowed*(ctx: BeaconCtxRef): uint64 =
  ctx.hdr.borrowed

proc headersUnprocChunks*(ctx: BeaconCtxRef): int =
  ctx.hdr.unprocessed.chunks()

proc headersUnprocIsEmpty*(ctx: BeaconCtxRef): bool =
  ctx.hdr.unprocessed.chunks() == 0

# ------------

proc headersUnprocInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.hdr.unprocessed = BnRangeSet.init()


proc headersUnprocClear*(ctx: BeaconCtxRef) =
  ## Clear
  ctx.hdr.unprocessed.clear()
  ctx.hdr.borrowed = 0u

proc headersUnprocSet*(ctx: BeaconCtxRef; minPt, maxPt: BlockNumber) =
  ## Set up new unprocessed range
  ctx.headersUnprocClear()
  # Argument `maxPt` would be internally adjusted to `max(minPt,maxPt)`
  if minPt <= maxPt:
    discard ctx.hdr.unprocessed.merge(minPt, maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

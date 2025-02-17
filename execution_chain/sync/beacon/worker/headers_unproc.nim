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
  doAssert ctx.hdr.borrowed.merge(iv) == iv.len
  ok(iv)


proc headersUnprocCommit*(ctx: BeaconCtxRef; iv: BnRange) =
  ## Commit back all processed range, i.e. remove it from the borrowed set.
  doAssert ctx.hdr.borrowed.reduce(iv) == iv.len

proc headersUnprocCommit*(ctx: BeaconCtxRef; iv, unproc: BnRange) =
  ## Variant of `headersUnprocCommit()` which merges back some unprocessed
  ## range `unproc`.
  doAssert ctx.hdr.borrowed.reduce(iv) == iv.len
  doAssert ctx.hdr.unprocessed.merge(unproc) == unproc.len

proc headersUnprocCommit*(
    ctx: BeaconCtxRef;
    iv: BnRange;
    uMinPt: uint64;
    uMaxPt: uint64) =
  ## Variant of `headersUnprocCommit()`which merges back some unprocessed
  ## range `[uMinPt,uMaxPt]`.
  doAssert ctx.hdr.borrowed.reduce(iv) == iv.len
  if uMinPt <= uMaxPt:
    # Otherwise `maxPt` would be internally adjusted to `max(minPt,maxPt)`
    doAssert ctx.hdr.unprocessed.merge(uMinPt, uMaxPt) == uMaxPt - uMinPt + 1


proc headersUnprocAppend*(ctx: BeaconCtxRef; minPt, maxPt: uint64) =
  ## Add some unprocessed range while leaving the borrowed queue untouched.
  ## The argument range will be curbed by existing `borrowed` entries (so
  ## it might become a set of ranges.)
  # Argument `maxPt` would be internally adjusted to `max(minPt,maxPt)`
  if minPt <= maxPt:
    if 0 < ctx.hdr.borrowed.covered(minPt, maxPt):
      # Must Reduce by currenty borrowed block numbers
      for pt in minPt .. maxPt:
        # So this is piecmeal adding to unprocessed numbers
        if ctx.hdr.borrowed.covered(pt,pt) == 0:
          discard ctx.hdr.unprocessed.merge(pt, pt)
    else:
      discard ctx.hdr.unprocessed.merge(minPt, maxPt)

proc headersUnprocAppend*(ctx: BeaconCtxRef; iv: BnRange) =
  ## Variant of `headersUnprocAppend()`
  ctx.headersUnprocAppend(iv.minPt, iv.maxPt)


proc headersUnprocAvail*(ctx: BeaconCtxRef): uint64 =
  ## Returns the number of headers that can be fetched
  ctx.hdr.unprocessed.total()

proc headersUnprocAvailTop*(ctx: BeaconCtxRef): uint64 =
  let iv = ctx.hdr.unprocessed.le().valueOr:
    return 0u64
  iv.maxPt


proc headersUnprocTotal*(ctx: BeaconCtxRef): uint64 =
  ctx.hdr.unprocessed.total() + ctx.hdr.borrowed.total()

proc headersUnprocTotalTop*(ctx: BeaconCtxRef): uint64 =
  ## Returns the higest number item from `borrowed` and `unprocessed` ranges.
  ## It will  default to `0` if both range sets are empty.
  let
    uMax = block:
      let rc = ctx.blk.unprocessed.ge(0)
      if rc.isOk:
        rc.value.maxPt
      else:
        0
    bMax = block:
      let rc = ctx.blk.borrowed.ge(0)
      if rc.isOk:
        rc.value.maxPt
      else:
        0
  min(uMax, bMax)

proc headersUnprocIsEmpty*(ctx: BeaconCtxRef): bool =
  ctx.hdr.unprocessed.chunks() == 0 and
  ctx.hdr.borrowed.chunks() == 0

proc headersBorrowedIsEmpty*(ctx: BeaconCtxRef): bool =
  ctx.hdr.borrowed.chunks() == 0

# ------------

proc headersUnprocInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.hdr.unprocessed = BnRangeSet.init()
  ctx.hdr.borrowed = BnRangeSet.init()

proc headersUnprocClear*(ctx: BeaconCtxRef) =
  ## Clear
  ctx.hdr.unprocessed.clear()
  ctx.hdr.borrowed.clear()

proc headersUnprocSet*(ctx: BeaconCtxRef; minPt, maxPt: uint64) =
  ## Set up new unprocessed range
  ctx.headersUnprocClear()
  if minPt <= maxPt:
    # Otherwise `maxPt` would be internally adjusted to `max(minPt,maxPt)`
    discard ctx.hdr.unprocessed.merge(minPt, maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

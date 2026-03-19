# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[stint, stew/interval_set],
  ../helpers,
  ./state_item_key

type
  UnprocItemKeys* = object
    unprocessed*: ItemKeyRangeSet    ## `ItemKey` processing requested
    borrowed*: ItemKeyRangeSet       ## In-process/locked ranges

# ------------------------------------------------------------------------------
# Public constructor & friends
# ------------------------------------------------------------------------------

proc init*(udb: var UnprocItemKeys) =
  udb.unprocessed = ItemKeyRangeSet.init()
  udb.borrowed = ItemKeyRangeSet.init()

proc init*(udb: var UnprocItemKeys; initRange: ItemKeyRange) =
  udb.init()
  discard udb.unprocessed.merge initRange


proc clear*(udb: var UnprocItemKeys) =
  ## Reset argument range sets empty.
  udb.unprocessed.clear
  udb.borrowed.clear

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchLeast*(udb: UnprocItemKeys; maxLen: UInt256): Opt[ItemKeyRange] =
  ## Fetch the least/leftmost interval from `ItemKey` ranges with maximal size
  ## `maxLen`, where `0` is interpreted as `2^256`.
  ##
  let
    # Fetch bottom/left interval with least block numbers
    jv = udb.unprocessed.ge().valueOr:
      return err()

    # Curb interval to maximal length (note `0` => `2^256`)
    iv = block:
      if maxLen == 0 or (jv.len != 0 and jv.len <= maxLen):
        jv
      else:
        # Curb interval `jv` to length `maxLen`
        #
        # Note that either (fringe case):
        #   (`jv.len`==0)  => (`jv`==`[0,high()]`) => `jv.maxPt`==`high()`
        # or (in the non-fringe case)
        #   (`maxLen` < `jv.len`) => (`jv.minPt` + `maxLen` - 1 < `jv.maxPt`)
        #
        ItemKeyRange.new(jv.minPt, jv.minPt + (maxLen - 1.u256))

  doAssert udb.unprocessed.reduce(iv) == iv.len
  doAssert udb.borrowed.merge(iv) == iv.len
  ok(iv)

proc fetchSubRange*(
    udb: UnprocItemKeys;
    iv: ItemKeyRange;
      ): Opt[ItemKeyRange] =
  ## Fetch a sub-interval of the argument interval `iv` from the unprocessed
  ## data ranges.
  ##
  var kv: ItemKeyRange
  block body:
    # Note that `iv.len` is a represented by the residue class mod `2^256`.
    # So `iv.len == 0` indicates that the size is 2^256 as interval cannot
    # be empty by definition.
    if iv.len == 0:                                 # => 2^256, largest interval
      kv = udb.unprocessed.ge().valueOr:
        return err()                                # no data
      break body
    let covered = udb.unprocessed.covered(iv)
    if covered == iv.len:
      kv = iv                                       # total overlap
      break body
    if covered == 0:
      return err()                                  # no overlap, at all

    # Now, there us a partial overlap of `iv` with the `unprocessed`
    # interval set.
    udb.unprocessed.ge(iv.minPt).isErrOr:
      # Found closest interval `value` which left point does not start before
      # the left point of `iv`.
      #   iv:        [-------..
      #   value:       [-----..

      if value.maxPt <= iv.maxPt:
        # iv:        [--------------]
        # value:       [---------]
        kv = value
        break body

      if value.minPt <= iv.maxPt:
        # iv:        [--------------]
        # value:       [----------------]
        kv = ItemKeyRange.new(value.minPt, iv.maxPt)
        break body

      # Get predecessor interval of `value` interval, `jv` say. Note that
      # there is an overlap of `iv` with some interval from `unprocessed`.
      # So `jv` exists and the start `jv` is before `iv`.
      #   iv:        [--------------]
      #   value:                      [-----]
      #   jv:   ..---------]
      let jv = udb.unprocessed.le(value.minPt).expect "Valid interval"
      kv = ItemKeyRange.new(iv.minPt,jv.maxPt)
      # break body

  doAssert udb.unprocessed.reduce(kv) == kv.len
  doAssert udb.borrowed.merge(kv) == kv.len
  ok(kv)


proc commit*(
    udb: UnprocItemKeys;
    iv: ItemKeyRange;                               # from `fetchLeast()`
      ) =
  ## Commit back all of processed range, i.e. remove it from the borrowed set
  ##
  doAssert udb.borrowed.reduce(iv) == iv.len

proc commit*(
    udb: UnprocItemKeys;
    iv: ItemKeyRange;                               # from `fetchLeast()`
    unproc: ItemKeyRange;                           # unprocessed sub-interval
      ) =
  ## Variant of `commit()` which merges back some unprocessed range `unproc`
  ##
  doAssert udb.borrowed.reduce(iv) == iv.len
  doAssert udb.unprocessed.merge(unproc) == unproc.len

proc commit*(
    udb: UnprocItemKeys;
    iv: ItemKeyRange;                               # from `fetchLeast()`
    minKey: ItemKey;                                # unprocessed intv. start
    maxKey: ItemKey;                                # unprocessed intv. last
      ) =
  ## Variant of `commit()` which merges back some unprocessed
  ## range `[minKey,maxKey]`
  ##
  doAssert udb.borrowed.reduce(iv) == iv.len
  if minKey <= maxKey:
    # Otherwise `maxKey` would be internally adjusted to `max(minKey,maxKey)`
    doAssert udb.unprocessed.merge(minKey, maxKey) == maxKey - minKey + 1

proc overCommit*(
    udb: UnprocItemKeys;
    minKey: ItemKey;                                # processed intv. start
    maxKey: ItemKey;                                # processed intv. last
      ) =
  ## Reduce unprocessed list by some range `[minKey,maxKey]`. This happens
  ## typically when a bit more accont or storage items are send via `snap`
  ## than requested.
  ##
  if minKey <= maxKey:
    discard udb.unprocessed.reduce(minKey, maxKey)


proc append*(udb: UnprocItemKeys; minKey, maxKey: ItemKey) =
  ## Add some unprocessed range while leaving the borrowed queue untouched.
  ## The argument range will be curbed by existing `borrowed` entries (so
  ## it might become a set of ranges.)
  ##
  if minKey <= maxKey:
    # Otherwise `maxKey` would be internally adjusted to `max(minKey,maxKey)`
    if 0 < udb.borrowed.covered(minKey, maxKey):
      # Must Reduce by currenty borrowed block numbers
      for key in minKey.to(UInt256) .. maxKey.to(UInt256):
        # So this is piecmeal adding to unprocessed numbers
        if udb.borrowed.covered(ItemKey(key), ItemKey(key)) == 0:
          discard udb.unprocessed.merge(ItemKey(key), ItemKey(key))
    else:
      discard udb.unprocessed.merge(minKey, maxKey)


func avail*(udb: UnprocItemKeys): Opt[UInt256] =
  ## Returns the number of `ItemKey` entries that can be fetched (maybe split
  ## across several intervals.)
  ##
  ## Due to residue class arithmetic and limitations of the number range
  ## `UInt256`, the maximum value `1+2^256` is returned as `ok(0)`, while the
  ## least value `0` is returned as `err()`.
  ##
  if udb.unprocessed.chunks() == 0:
    err()                                           # representing zero items
  else:
    ok udb.unprocessed.total()

func availBottom*(udb: UnprocItemKeys): ItemKey =
  ## Returns the least `ItemKey` entity from the `unprocessed` ranges set. It
  ## will default to `high(ItemKey)` if the range set is empty.
  ##
  let iv = udb.unprocessed.ge().valueOr:
    return high(ItemKey)
  iv.minPt

func availTop*(udb: UnprocItemKeys): ItemKey =
  ## Returns the largest`ItemKey` entity from the `unprocessed` ranges set. It
  ## will default to `0` if the range set is empty.
  ##
  let iv = udb.unprocessed.le().valueOr:
    return low(ItemKey)                             # aka 0 representing `2^256`
  iv.maxPt


func total*(udb: UnprocItemKeys): Opt[UInt256] =
  ## Returns the sum of `borrowed` and `unprocessed` range sizes.
  ##
  ## Due to residue class arithmetic and limitations of the number range
  ## `UInt256`, the maximum value `2^256` is returned as `ok(0)`, while the
  ## least value `0` (i.e. nothing left) is returned as `err()`.
  ##
  if udb.borrowed.chunks() == 0:
    udb.avail()
  else:
    let b = udb.borrowed.total()
    if udb.unprocessed.chunks() == 0:
      ok(b)                                         # 0 represents `2^256`
    else:
      let ub = udb.unprocessed.total() + (b - 1)
      if ub == high(UInt256):                       # which is `2^256-1`
        ok(low UInt256)                             # aka 0 representing `2^256`
      else:
        ok(ub+1)


func totalBottom*(udb: UnprocItemKeys): ItemKey =
  ## Returns the least `ItemKey` entity from `borrowed` and `unprocessed`
  ## ranges merged together. It will return `high(ItemKey)` if both range
  ## sets are empty.
  ##
  let
    uMin = block:
      let rc = udb.unprocessed.ge()
      if rc.isOk:
        rc.value.minPt
      else:
        high(ItemKey)
    bMin = block:
      let rc = udb.borrowed.ge()
      if rc.isOk:
        rc.value.minPt
      else:
        high(ItemKey)
  min(uMin, bMin)

func totalTop*(udb: UnprocItemKeys): ItemKey =
  ## Returns the largest `ItemKey` entity from `borrowed` and `unprocessed`
  ## ranges merged together. It will return `low(ItemKey)` (aka 0) if both
  ## range sets are empty.
  ##
  let
    uMax = block:
      let rc = udb.unprocessed.le()
      if rc.isOk:
        rc.value.maxPt
      else:
        low(ItemKey)
    bMax = block:
      let rc = udb.borrowed.le()
      if rc.isOk:
        rc.value.maxPt
      else:
        low(ItemKey)
  max(uMax, bMax)


func totalRatio*(udb: UnprocItemKeys): float =
  ## The function returns the factor of how much more data are to be processed
  ## (i.e. `total()/2^256`.) This calculation considers borrowed ranges as
  ## unprocessed.
  ##
  ## This function returns an approximation only of the real factor due to
  ## lossy conversion from `UInt256` values to `float`.
  ##
  udb.total().per256()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

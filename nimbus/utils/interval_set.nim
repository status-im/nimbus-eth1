# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Efficient set of non-adjacent disjunct intervals
## ================================================
##
## This molule efficiently manages a set `Q` of non-adjacent intervals `I`
## over a scalar type `S`. The elements of the intervals are not required to
## be scalar, yet they need to fulfil some ordering properties and must map
## into `S` by the `-` operator.
##
## Application examples
## --------------------
## * Intervals `I` are sub-ranges of `distinct uint`, scalar `S` is `uint64`
## * Intervals `I` are sub-ranges of `distinct UInt256`, scalar `S` is `Uint256`
## * Intervals `I` art sub-ranges of `uint`, scalar `S` is `uint`
##
## Mathematical heuristic reasoning
## --------------------------------
## Let `S` be a scalar structure isomorphic to a sub-ring of `Z`, the ring of
## integers. Typical representants would be `uint`, `uint64`, `UInt256` when
## seen as residue classes. `S` need not be bounded. We require `0` and `1` in
## `S`.
##
## Define `P` as a finite set of elements with the following properties:
##
## * There is an order relation defined on `P` (ie. `<`, `=` exists and is
##   transitive.)
##
## * Define an interval `I` to be a set of elements of `P` with:
##   + If `a`,`b` are in `I`, `w` in `P` with `a<=w<=b`, then `b` is in `I`.
##   + We write `[a,b]` for the interval `I` with `a=min(I)` and `b=max(I)`.
##   + We have `P=[min(P),max(P)]` (note that `P` is ordered.)
##
## * There is a binary *minus* operation `-:PxP -> S` with the following
##   properties:
##   + If `a`, `b` are in `P` and `a<=b`, then`b-a=card([a,b])-1`. So
##     `a-a=0` for all `a`.
##   + For any `a<max(P)`, there is a unique element `b=min{w|a<w}` with
##     `b-a=1`. We write `a+1` instead of `b`.
##   + Ditto for `a-1` when `min(P)<a`
##
## * The elements of `P` are called points.
##
## Efficiency of managing `Q`
## --------------------------
## The set `Q` of non-adjacent intervals is constructed as follows:
## * For `I`, `J` intervals over `P`, define the envelope `I~J` as
##  `[min(I+J),max(I+J)]` derived by interpolating elements beween `I`
##   and `J`. Clearly, `card(I+J)<=card(I~J)` holds (where `+` denotes the
##   union of sets.)
## * For different `I`, `J` in `Q`, we require `card(I+J)<card(I~J)`. This
##   is the defining property for non-adjacent intervals.
##
## The set of intervals `Q` is implemented based on an `O(log n)` complexity
## `SortedSet` database (where `n` is the size of the database.)
##
## An operation on `Q` involving an interval `I` is of complexity
## `O(log n)+O(card I)` where `card I` is the number of elements in `I`.
## The worst case complexity applies if every other element of `I` is present
## as a single element interval in `Q`. So when merging, or reducing the
## set `Q` by the interval `I`, every other element of `I` that is
## in the set `Q` will be touched. This number of operations is at most
## `1 + (card I) / 2`.
##
## Data type requirements
## ----------------------
## The following operations must be made available when implementing `P`:
##
## * Order relation stuff for points of `P`: `==`, `<`, `cmp`, etc.
## * Maximum and minimum points `high(P)` and `low(P)` must be defined
## * Difference of points: `-:PxP -> S`, ie. `b-a` is of scalar type `S`.
## * Right addition of scalar: `+:PxS -> P`, ie. `a+n` is a point `b` and
##   `b-a` is `n`.
## * The function `$()` must be defined (used for debugging, only)
##
## Additional requirements for the scalar type `S`:
##
## * `S.default` must be the `0` element (of the additive group)
## * `S.default+1` must be the `1` element (of the implied multiplicative
##   group)
## * The scalar space `S` must contain all the numbers `0 .. high(P)-low(P)`
##
## User interface considerations
## -----------------------------
## The data set descriptor is implemented as an object reference. For deep
## copy and deep comparison, the functions `dup()` and `==` are provided.
##
## For any function, the argument points of `P` are assumed be in the
## range `low(P) .. high(P)`. This is not checked explicitely. Using points
## outside this range might have unintended side effects (applicable only
## if `P` is a proper sub-range of a larger data range.)
##
## The data set represents compact intervals `[a,b]` over a point space `P`
## where the length of the largest possible interval is `card(P)` which might
## exceed the highest available scalar `high(S)` from the *NIM* implementation
## of `S`. In order to handle the scalar equivalent of `card(P)`, this package
## always returns the scalar *zero* (from the scalar space `S`) for `card(S)`.
## This makes mathematically sense when `P` is seen as a residue class
## isomorpic to a subclass of `S`.
##

import
  stew/[results, sorted_set]

{.push raises: [Defect].}

export
  `isRed=`,
  `linkLeft=`,
  `linkRight=`

const
  NoisyDebuggingOk = false

type
  IntervalSetError* = enum
    ## Used for debugging only, see `verify()`
    isNoError = 0
    isErrorBogusInterval   ## Illegal interval end points or zero size
    isErrorOverlapping     ## Overlapping intervals in database
    isErrorAdjacent        ## Adjacent intervals, should be joined
    isErrorTotalMismatch   ## Total accumulator resiter is wrong

  Interval*[P,S] = object
    ## Compact interval `[least,last]`
    least, last: P

  IntervalRc*[P,S] = ##\
    ## Handy shortcut, used for interval operation results
    Result[Interval[P,S],void]

  IntervalSetRef*[P,S] = ref object
    ## Set of non-adjacent intervals
    ptsCount: S
      ## data size covered

    leftPos: SortedSet[P,BlockRef[S]]
      ## list of segments, half-open intervals

    lastHigh: bool
      ## `true` iff `high(P)` is in the interval set

  # -----

  Desc[P,S] = ##\
    ## Internal shortcut, interval set
    IntervalSetRef[P,S]

  Segm[P,S] = object
    ## Half open interval `[start,start+size)`
    start: P  ## Start point
    size: S   ## Length of interval

  BlockRef[S] = ref object
    ## Internal, interval set database record reference
    size: S

  DataRef[P,S] = ##\
    ## Internal, shortcut: The `value` part of a successful `SortedSet`
    ## operation, a reference to the stored data record.
    SortedSetItemRef[P,BlockRef[S]]

  Rc[P,S] = ##\
    ## Internal shortcut
    Result[DataRef[P,S],void]

# ------------------------------------------------------------------------------
# Private debugging
# ------------------------------------------------------------------------------

when NoisyDebuggingOk:
  import std/[sequtils, strutils]

  # Forward declarations
  proc verify*[P,S](
    ds: IntervalSetRef[P,S]): Result[void,(RbInfo,IntervalSetError)]

  proc sayImpl(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
    if noisy:
      if args.len == 0:
        echo "*** ", pfx
      elif 0 < pfx.len and pfx[^1] != ' ':
        echo pfx, " ", args.toSeq.join
      else:
        echo pfx, args.toSeq.join

  proc pp[P,S](ds: Desc[P,S]): string =
    if ds.isNil:
      "nil"
    else:
      cast[pointer](ds).repr.strip

  proc pp[P,S](iv: Segm[P,S]): string =
    "[" & $iv.left & "," & $iv.right & ")"

  proc pp[P,S](iv: Interval[P,S]): string =
    template one: (S.default + 1)
    result = "[" & $iv.least & ","
    if high(P) <= iv.last:
      result &= "high(P)"
    elif (high(P) - one) <= iv.last:
      result &= "high(P)-1"
    elif (high(P) - one - one) == iv.last:
      result &= "high(P)-2"
    else:
      result &= $iv.last
    result &= "]"

  proc pp[P,S](kvp: DataRef[P,S]): string =
    Segm[P,S].new(kvp).pp

var
  noisy* = false

template say(noisy = false; pfx = "***"; v: varargs[untyped]): untyped =
  when NoisyDebuggingOk:
    noisy.sayImpl(pfx, v)
  discard

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template maxSegmSize(): untyped =
  (high(P) - low(P))

template scalarZero(): untyped =
  ## the value `0` from the scalar data type
  (S.default)

template scalarOne(): untyped =
  ## the value `1` from the scalar data type
  (S.default + 1)

proc blk[P,S](kvp: DataRef[P,S]): BlockRef[S] =
  kvp.data

proc left[P,S](kvp: DataRef[P,S]): P =
  kvp.key

proc right[P,S](kvp: DataRef[P,S]): P =
  kvp.key + kvp.blk.size

proc len[P,S](kvp: DataRef[P,S]): S =
  kvp.data.size

# -----

proc new[P,S](T: type Segm[P,S]; kvp: DataRef[P,S]): T =
  T(start: kvp.left, size: kvp.blk.size)

proc new[P,S](T: type Segm[P,S]; left, right: P): T =
  ## Constructor using `[left,right)` points representation
  T(start: left, size: right - left)

proc left[P,S](iv: Segm[P,S]): P =
  iv.start

proc right[P,S](iv: Segm[P,S]): P =
  iv.start + iv.size

proc len[P,S](iv: Segm[P,S]): S =
  iv.size

# ------

proc `+=`[P,S](a: var P; n: S) =
  ## Might not be generally available for point `P` and scalar `S`
  a = a + n

proc maxPt[P](a, b: P): P =
  ## Instead of max() which might not be generally available
  if a < b: b else: a

proc minPt[P](a, b: P): P =
  ## Instead of min() which might not be generally available
  if a < b: a else: b

# ------

proc new[P,S](T: type Interval[P,S]; kvp: DataRef[P,S]): T =
  T(least: kvp.left, last: kvp.right - scalarOne)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc overlapOrLeftJoin[P,S](ds: Desc[P,S]; l, r: P): Rc[P,S] =
  ## Find and return
  ## * either the rightmost `[l,r)` overlapping interval `[a,b)`
  ## * or `[a,b)` with `b==l`
  if l < r:
    let rc = ds.leftPos.le(r) # search for `max(a) <= r`
    if rc.isOK:
      # note that `b` is the first point outside right of `[a,b)`
      let b = rc.value.right
      if l <= b:
        return ok(rc.value)
  err()

proc overlapOrLeftJoin[P,S](ds: Desc[P,S]; iv: Segm[P,S]): Rc[P,S] =
  ds.overlapOrLeftJoin(iv.left, iv.right)


proc overlap[P,S](ds: Desc[P,S]; l, r: P): Rc[P,S] =
  ## Find and return the rightmost `[l,r)` overlapping interval `[a,b)`.
  if l < r:
    let rc = ds.leftPos.lt(r) # search for `max(a) < r`
    if rc.isOK:
      # note that `b` is the first point outside right of `[a,b)`
      let b = rc.value.right
      if l < b:
        return ok(rc.value)
  err()

proc overlap[P,S](ds: Desc[P,S]; iv: Segm[P,S]): Rc[P,S] =
  ds.overlap(iv.left, iv.right)

# ------------------------------------------------------------------------------
# Private transfer function helpers
# ------------------------------------------------------------------------------

proc findInlet[P,S](ds: Desc[P,S]; iv: Segm[P,S]): Segm[P,S] =
  ## Find largest sub-segment of `iv` fully contained in another segment
  ## of the argument database.
  ##
  ## If the `src` argument is `nil`, the argument interval `iv` is returned.
  ## If there is no overlapping segment, the empty interval
  ##`[iv.start,iv.start)` is returned.

  # Handling edge cases
  if ds.isNil:
    return iv

  let rc = ds.overlap(iv)
  if rc.isErr:
    return Segm[P,S].new(iv.left, iv.left)

  let p = rc.value
  Segm[P,S].new(maxPt(p.left,iv.left), minPt(p.right,iv.right))


proc merge[P,S](ds: Desc[P,S]; iv: Segm[P,S]): Segm[P,S] =
  # Merge argument into into database and returns added segment (if any)

  noisy.say "***", "merge(1)",
    " ds=", ds.pp, " iv=", iv.pp

  if ds.isNil:
    return iv

  let p = block:
    let rc = ds.overlapOrLeftJoin(iv)
    if rc.isErr:
      let rx = ds.leftPos.insert(iv.left)
      rx.value.data = BlockRef[S](size: iv.len)
      ds.ptsCount += iv.len
      return iv
    rc.value # `rc.value.data` is a reference to the database record

  doAssert p.blk.size <= ds.ptsCount

  if p.right < iv.right:
    #
    #     iv:     ...----------------)
    #     p:      ...-----)
    #
    p.blk.size += iv.len # update database
    ds.ptsCount += iv.len   # update database
    #
    #     iv:     ...----------------)
    #     p:      ...----------------)
    #     result:          [---------)
    #
    return Segm[P,S].new(p.right, iv.right)

  # now: iv.right <= p.right and p.left <= iv.left:
  if p.left <= iv.left:
    #
    #     iv:         [--------)
    #     p:      [-------------------)
    #     result:     o
    #
    return Segm[P,S].new(iv.left, iv.left) # empty interval

  # now: iv.right <= p.right and iv.left < p.left
  if p.left < iv.right:
    #
    #     iv:     [-----------------)
    #     p:              [--------------)
    #     result: [------)
    #
    result = Segm[P,S].new(iv.left, p.left)
  else:
    #     iv:     [------)
    #     p:              [--------------)
    #     result: [------)
    #
    result = iv

  noisy.say "***", "merge(2)",
    " iv=", iv.pp, " p=", p.pp, " result=", result.pp

  # No need for interval `p` anymore.
  doAssert p.left == result.right
  ds.ptsCount -= p.len
  discard ds.leftPos.delete(p.left)

  # Check whether there is an `iv` left overlapping interval `q` that can be
  # merged.
  #
  # Note that the deleted `p` was not fully contained in `iv`. So any overlap
  # must be a predecessor. Also, the right end point of the `iv` interval is
  # not part of any predecessor because it was adjacent to, or overlapping with
  # the deleted interval `p`.
  let rc = ds.overlapOrLeftJoin(iv.left, iv.right - scalarOne)
  if rc.isOk and iv.left <= rc.value.right:
    let q = rc.value

    noisy.say "***", "merge(3)",
      " iv=", iv.pp, " p=", p.pp, " q=", q.pp, " result=", result.pp
    #
    #   iv:         [------...
    #   p:                  [------)    // deleted
    #   q:       [----)
    #   result:     [------)
    #
    result = Segm[P,S].new(q.right, result.right)
    #
    #   iv:         [------...
    #   p:                  [------)    // deleted
    #   q:       [----)
    #   result:        [---)
    #
    # extend `q` to join `result` and `p`, now
    let exLen = result.len + p.len
    q.blk.size += exLen
    ds.ptsCount += exLen
    #
    #   iv:         [------...
    #   p:                  [------)    // deleted
    #   q:       [-----------------)
    #   result:       [----)
    #
  else:
    # So `iv` is fully isolated, i.e. there is no join or overlap. And `iv`
    # joins or overlaps the deleted `p` but does not exceed its right end.
    #
    #   iv:         [-----------)
    #   p:                  [------)    // deleted
    #   result:       [----)
    #
    let s = BlockRef[S](size: p.right - iv.left)
    ds.leftPos.insert(iv.left).value.data = s
    ds.ptsCount += s.size
    #
    #   iv:         [------)
    #   p:                  [------)    // deleted
    #   result:       [----)
    #   s:          [--------------)


proc deleteInlet[P,S](ds: Desc[P,S]; iv: Segm[P,S]) =
  ## Delete fully contained interval
  if not ds.isNil and 0 < iv.len:

    let
      p = ds.overlap(iv).value  # `p.blk` is a reference into database
      right = p.right           # fix the right end for later trailer handling

    # [iv) fully contained in [p)
    doAssert p.left <= iv.left and iv.right <= p.right

    if p.left == iv.left:
      #
      #    iv:   [--------------)
      #    p:    [---------------...     // deleting
      #
      discard ds.leftPos.delete(p.left)
      ds.ptsCount -= p.len
    else:
      #    iv:           [-------)
      #    p:    [----------------...
      #
      let chop = p.right - iv.left # positive as iv.left<iv.right<=p.right
      p.blk.size -= chop           # update database
      ds.ptsCount -= chop             # update database
      #
      #    iv:           [-------)
      #    p.blk: [-----)         ...)
      #                              ^
      #                              |
      #                              right

    # Correct: re-add trailer
    if iv.right < right:
      #
      #    iv:   ...-------)
      #    p:       [---------------)    // may have been deleted in `==` clause
      #    s:               [-------)    // adding to database
      #
      let s = BlockRef[S](size: right - iv.right)
      ds.leftPos.insert(iv.right).value.data = s
      ds.ptsCount += s.size

# ------------------------------------------------------------------------------
# Private transfer() function implementation for merge/reduce
# ------------------------------------------------------------------------------

proc transferImpl[P,S](src, trg: Desc[P,S]; iv: Segm[P,S]): S =
  ## From the `src` argument database, delete the data segment/interval
  ## `[start,start+length)` and merge it into the `trg` argument database.
  ## Not both  arguments `src` and `trg` must be `nil`.
  doAssert not (src.isNil and trg.isNil)

  var pfx = iv

  noisy.say "***", "transfer(1)",
    " src=", src.pp, " pfx=", pfx.pp, " trg=", trg.pp

  while 0 < pfx.len:
    # Find sub-interval of `[pfx)` fully contained in a `src` database interval
    var fromIv = src.findInlet(pfx)

    noisy.say "***", "transfer(2)",
      " pfx=", pfx.pp, " fromIv=", fromIv.pp, "\n"

    # Chop right end from [pfx) -> [pfx) + [fromIv)
    pfx = Segm[P,S].new(pfx.left, fromIv.left)

    # Move the `fromIv` interval from `src` to `trg` database
    while 0 < fromIv.len:
      # Merge sub-interval `[fromIv)` into `trg` database
      let toIv = trg.merge(fromIv)

      noisy.say "***", "transfer(3)",
        " pfx=", pfx.pp, " fromIv=", fromIv.pp, " toIv=", toIv.pp

      # Chop right end from [fromIv) -> [fromIv) + [toIv)
      fromIv = Segm[P,S].new(fromIv.left, toIv.left)

      # Delete merged sub-interval from `src` database (if any)
      src.deleteInlet(toIv)

      result += toIv.len

    noisy.say "***", "transfer(9)",
      " pfx=", pfx.pp, " fromIv=", fromIv.pp, " result=", result

# ------------------------------------------------------------------------------
# Private covered() function implementation
# ------------------------------------------------------------------------------

proc coveredImpl[P,S](ds: IntervalSetRef[P,S]; start: P; length: S): S =
  ## Calulate the accumulated size of the interval `[start,start+length)`
  ## covered by intervals in the set `ds`. The result cannot exceed the
  ## argument `length` (of course.)
  var iv = Segm[P,S](start: start, size: length)

  noisy.say "***", "covered(1)", " iv=", iv.pp

  while 0 < iv.len:
    let rc = ds.overlap(iv)
    if rc.isErr:
      noisy.say "***", "covered(2)", " iv=", iv.pp, " no oberlap"
      break

    let p = rc.value
    noisy.say "***", "covered(3)", " iv=", iv.pp, " p=", p.pp

    # Now `p` is the right most interval overlapping `iv`
    if p.left <= iv.left:
      if p.right <= iv.right:
        #
        #    iv:             [----------------)
        #    p:         [-------------)
        #    overlap:        <------->
        #
        result += p.right - iv.left
      else:
        #    iv:             [--------)
        #    p:         [--------------------)
        #    overlap:        <------->
        #
        result += iv.len
      break
    else:
      if iv.right < p.right:
        #
        #    iv:        [--------------)
        #    p:              [--------------)
        #    overlap:        <-------->
        #
        result += iv.right - p.left
      else:
        #    iv:        [----------------------)
        #    p:              [----------)
        #    overlap:        <--------->
        #
        result += p.len

      iv.size = p.left - iv.left
      #      iv:        [---)
      #      p:              [----------)

# ------------------------------------------------------------------------------
# Public constructor, clone, etc.
# ------------------------------------------------------------------------------

proc init*[P,S](T: type IntervalSetRef[P,S]): T =
  ## Interval set constructor.
  new result
  result.leftPos.init()

proc clone*[P,S](ds: IntervalSetRef[P,S]): IntervalSetRef[P,S] =
  ## Return a copy of the interval list. Beware, this might be slow as it
  ## needs to copy every interval record.
  result = Desc[P,S].init()
  result.ptsCount = ds.ptsCount
  result.lastHigh = ds.lastHigh

  var # using fast traversal
    walk = SortedSetWalkRef[P,BlockRef[S]].init(ds.leftPos)
    rc = walk.first
  while rc.isOk:
    result.leftPos.insert(rc.value.key)
      .value.data = BlockRef[S](size: rc.value.data.size)
    rc = walk.next
  # optional clean up, see comments on the destroy() directive
  walk.destroy

proc `==`*[P,S](a, b: IntervalSetRef[P,S]): bool =
  ## Compare interval sets for equality. Beware, this can be slow. Every
  ## interval record has to be checked.
  if a.ptsCount == b.ptsCount and
     a.leftPos.len == b.leftPos.len and
     a.lastHigh == b.lastHigh:
    result = true
    if 0 < a.ptsCount and addr(a.leftPos) != addr(b.leftPos):
      var # using fast traversal
        aWalk = SortedSetWalkRef[P,BlockRef[S]].init(a.leftPos)
        aRc = aWalk.first()
      while aRc.isOk:
        let bRc = b.leftPos.eq(aRc.value.key)
        if bRc.isErr or aRc.value.data.size != bRc.value.data.size:
          result = false
          break
        aRc = aWalk.next()
      # optional clean up, see comments on the destroy() directive
      aWalk.destroy()

proc clear*[P,S](ds: IntervalSetRef[P,S]) =
  ## Clear the interval set.
  ds.ptsCount = scalarZero
  ds.lastHigh = false
  ds.leftPos.clear()

proc new*[P,S](T: type Interval[P,S]; minPt, maxPt: P): T =
  ## Create interval `[minPt,max(minPt,maxPt)]`
  Interval[P,S](least: minPt, last: max(minPt, maxPt))

# ------------------------------------------------------------------------------
# Public interval operations add, remove, erc.
# ------------------------------------------------------------------------------

proc merge*[P,S](ds: IntervalSetRef[P,S]; minPt, maxPt: P): S =
  ## For the argument interval `I` implied as `[minPt,max(minPt,maxPt)]`,
  ## merge `I` with the intervals of the argument set `ds`. The function
  ## returns the accumulated number of points that were added to some
  ## interval (i.e. which were not contained in any interval of `ds`.)
  ##
  ## If the argument interval `I` is `[low(P),high(P)]` and is fully merged,
  ## the scalar *zero* is returned instead of `high(P)-low(P)+1` (which might
  ## not exisit in `S`.).
  let length =
    if maxPt <= minPt:
      scalarOne
    elif maxPt < high(P):
      (maxPt - minPt) + scalarOne
    else:
      (high(P) - minPt)

  result = transferImpl[P,S]( # zero length is ok
    src=nil, trg=ds, iv=Segm[P,S](start: minPt, size: length))

  if high(P) <= maxPt and not ds.lastHigh:
    ds.lastHigh = true
    if result < maxSegmSize:
      result += scalarOne
    else:
      result = scalarZero

proc reduce*[P,S](ds: IntervalSetRef[P,S]; minPt, maxPt: P): S =
  ## For the argument interval `I` implied as `[minPt,max(minPt,maxPt)]`,
  ## remove the points from `I` from intervals of the argument set `ds`.
  ## The function returns the accumulated number of elements removed (i.e.
  ## which were previously contained in some interval of `ds`.)
  ##
  ## If the argument interval `I` is `[low(P),high(P)]` and is fully removed,
  ## the scalar *zero* is returned instead of `high(P)-low(P)+1` (which might
  ## not exisit in `S`.).
  let length =
    if maxPt <= minPt:
      scalarOne
    elif maxPt < high(P):
      (maxPt - minPt) + scalarOne
    else:
      (high(P) - minPt)

  result = transferImpl[P,S]( # zero length is ok
    src=ds, trg=nil, iv=Segm[P,S](start: minPt, size: length))

  if high(P) <= maxPt and ds.lastHigh:
    ds.lastHigh = false
    if result < maxSegmSize:
      result += scalarOne
    else:
      result = scalarZero

proc covered*[P,S](ds: IntervalSetRef[P,S]; minPt, maxPt: P): S =
  ## For the argument interval `I` implied as `[minPt,max(minPt,maxPt)]`,
  ## calulate the accumulated points `I` contained in some interval in the
  ## set `ds`. The return value is the same as that for `reduce()` (only
  ## that `ds` is left unchanged, here.)
  let length =
    if maxPt <= minPt:
      scalarOne
    elif maxPt < high(P):
      (maxPt - minPt) + scalarOne
    else:
      (high(P) - minPt)

  result = ds.coveredImpl(minPt, length) # zero length is ok

  if high(P) <= maxPt and ds.lastHigh:
    if result < maxSegmSize:
      result += scalarOne
    else:
      result = scalarZero


proc ge*[P,S](ds: IntervalSetRef[P,S]; minPt: P): IntervalRc[P,S] =
  ## Find smallest interval in the set `ds` with start point (i.e. minimal
  ## value in the interval as a set) greater or equal the argument `minPt`.
  let rc = ds.leftPos.ge(minPt)
  if rc.isOK:
    # Check for fringe case intervals [a,b] + [high(P),high(P)]
    if high(P) <= rc.value.right and ds.lastHigh:
      return ok(Interval[P,S].new(rc.value.left, high(P)))
    return ok(Interval[P,S].new(rc.value))
  if ds.lastHigh:
    return ok(Interval[P,S].new(high(P),high(P)))
  err()

proc ge*[P,S](ds: IntervalSetRef[P,S]): IntervalRc[P,S] =
  ## Find the interval with the least elements of type `P` (if any.)
  ds.ge(low(P))

proc le*[P,S](ds: IntervalSetRef[P,S]; maxPt: P): IntervalRc[P,S] =
  ## Find largest interval in the set `ds` with end point (i.e. maximal
  ## value in the interval as a set) smaller or equal to the argument `maxPt`.
  let rc = ds.leftPos.le(maxPt)
  if rc.isOK:
    # only the left end of segment [left,right) is guaranteed to be <= maxPt
    if rc.value.right - scalarOne <= maxPt:
      if high(P) <= maxPt and ds.lastHigh:
        # Check for fringe case intervals [a,b] gap [high(P),high(P)] <= maxPt
        if rc.value.right < high(P):
          return ok(Interval[P,S].new(high(P),high(P)))
        # Check for fringe case intervals [a,b] + [high(P),high(P)] <= maxPt
        if high(P) <= rc.value.right:
          return ok(Interval[P,S].new(rc.value.left,high(P)))
      return ok(Interval[P,S].new(rc.value))
    # find the next smaller one
    let xc = ds.leftPos.lt(rc.value.key)
    if xc.isOk:
      return ok(Interval[P,S].new(xc.value))
  # lone interval
  if high(P) <= maxPt and ds.lastHigh:
    return ok(Interval[P,S].new(high(P),high(P)))
  err()

proc le*[P,S](ds: IntervalSetRef[P,S]): IntervalRc[P,S] =
  ## Find the interval with the largest elements of type `P` (if any.)
  ds.le(high(P))


proc delete*[P,S](ds: IntervalSetRef[P,S]; minPt: P): IntervalRc[P,S] =
  ## Find the interval `[minPt,maxPt]` for some point `maxPt` in the interval
  ## set `ds` and remove it from `ds`. The function returns the deleted
  ## interval (if any.)
  block:
    let rc = ds.leftPos.delete(minPt)
    if rc.isOK:
      ds.ptsCount -= rc.value.len
      # Check for fringe case intervals [a,b]+[high(P),high(P)]
      if high(P) <= rc.value.right and ds.lastHigh:
        ds.lastHigh = false
        return ok(Interval[P,S].new(rc.value.left,high(P)))
      return ok(Interval[P,S].new(rc.value))
  if high(P) <= minPt and ds.lastHigh:
    # delete isolated point
    let rc = ds.leftPos.lt(minPt)
    if rc.isErr or rc.value.right < high(P):
      ds.lastHigh = false
      return ok(Interval[P,S].new(high(P),high(P)))
  err()


iterator increasing*[P,S](
    ds: IntervalSetRef[P,S];
    minPt = low(P)
      ): Interval[P,S] =
  ## Iterate in increasing order through intervals with points greater or
  ## equal than the argument point `minPt`.
  var rc = ds.leftPos.ge(minPt)
  while rc.isOk:
    let key = rc.value.key
    if high(P) <= rc.value.right and ds.lastHigh:
      yield Interval[P,S].new(rc.value.left,high(P))
    else:
      yield Interval[P,S].new(rc.value)
    rc = ds.leftPos.gt(key)

iterator decreasing*[P,S](
    ds: IntervalSetRef[P,S];
    maxPt = high(P)
      ): Interval[P,S] =
  ## Iterate in decreasing order through intervals with points less or equal
  ## than the argument point `maxPt`.
  var rc = ds.leftPos.le(maxPt)

  if rc.isOK:
    let key = rc.value.key
    # last entry: check for additional point
    if high(P) <= rc.value.right and ds.lastHigh:
      yield Interval[P,S].new(rc.value.left,high(P))
    else:
      yield Interval[P,S].new(rc.value)
    # find the next smaller one
    rc = ds.leftPos.lt(key)

  while rc.isOk:
    let key = rc.value.key
    yield Interval[P,S].new(rc.value)
    rc = ds.leftPos.lt(key)

# ------------------------------------------------------------------------------
# Public interval operators
# ------------------------------------------------------------------------------

proc `==`*[P,S](iv, jv: Interval[P,S]): bool =
  ## Compare intervals for equality
  iv.least == jv.least and iv.last == jv.last

proc `==`*[P,S](iv: IntervalRc[P,S]; jv: Interval[P,S]): bool =
  ## Variant of `==`
  if iv.isOk:
    return iv.value == jv

proc `==`*[P,S](iv: Interval[P,S]; jv: IntervalRc[P,S]): bool =
  ## Variant of `==`
  if jv.isOk:
    return iv == jv.value

proc `==`*[P,S](iv, jv: IntervalRc[P,S]): bool =
  ## Variant of `==`
  if iv.isOk:
    if jv.isOk:
      return iv.value == jv.value
    # false
  else:
    return jv.isErr
  # false

# ------

proc `*`*[P,S](iv, jv: Interval[P,S]): IntervalRc[P,S] =
  ## Intersect itervals `iv` and `jv` if this operation results in a
  ## non-emty interval. Note that the `*` operation is associative, i.e.
  ## ::
  ##  iv * jv * kv == (iv * jv) * kv == iv * (jv * kv)
  ##
  if jv.least <= iv.last and iv.least <= jv.last:
    # intervals overlap
    return ok(Interval[P,S].new(
      maxPt(jv.least,iv.least), minPt(jv.last,iv.last)))
  err()

proc `*`*[P,S](iv: IntervalRc[P,S]; jv: Interval[P,S]): IntervalRc[P,S] =
  ## Variant of `*`
  if iv.isOk:
    return iv.value * jv
  err()

proc `*`*[P,S](iv: Interval[P,S]; jv: IntervalRc[P,S]): IntervalRc[P,S] =
  ## Variant of `*`
  if jv.isOk:
    return iv * jv.value
  err()

proc `*`*[P,S](iv, jv: IntervalRc[P,S]): IntervalRc[P,S] =
  ## Variant of `*`
  if iv.isOk and jv.isOk:
    return iv.value * jv.value
  err()

# ------

proc `+`*[P,S](iv, jv: Interval[P,S]): IntervalRc[P,S] =
  ## Merge intervals `iv` and `jv` if this operation results in an interval.
  ## Note that the `+` operation is *not* associative, i.e.
  ## ::
  ##  iv + jv + kv == (iv + jv) + kv  is not necessarly  iv + (jv + kv)
  ##
  if iv.least <= jv.least:
    if jv.least - scalarOne <= iv.last:
      #
      #  iv:    [--------]
      #  jv:          [...[-----...
      #
      return ok(Interval[P,S].new(iv.least, maxPt(iv.last,jv.last)))

  else: # jv.least < iv.least
    if iv.least - scalarOne <= jv.last:
      #
      #  iv:          [...[-----...
      #  jv:    [--------]
      #
      return ok(Interval[P,S].new(jv.least, maxPt(iv.last,jv.last)))

  err()

proc `+`*[P,S](iv: IntervalRc[P,S]; jv: Interval[P,S]): IntervalRc[P,S] =
  ## Variant of `+`
  if iv.isOk:
    return iv.value + jv
  err()

proc `+`*[P,S](iv: Interval[P,S]; jv: IntervalRc[P,S]): IntervalRc[P,S] =
  ## Variant of `+`
  if jv.isOk:
    return iv + jv.value
  err()

proc `+`*[P,S](iv, jv: IntervalRc[P,S]): IntervalRc[P,S] =
  ## Variant of `+`
  if iv.isOk and jv.isOk:
    return iv.value + jv.value
  err()

# ------

proc `-`*[P,S](iv, jv: Interval[P,S]): IntervalRc[P,S] =
  ## Return the interval `iv` reduced by elements of `jv` if this operation
  ## results in a non-empty interval.
  ## Note that the `-` operation is *not* associative, i.e.
  ## ::
  ##  iv - jv - kv == (iv - jv) - kv  is not necessarly  iv - (jv - kv)
  ##
  if iv.least <= jv.least:
    if jv.least <= iv.last and iv.last <= jv.last:
      #
      #  iv:    [--------------]
      #  jv:          [------------]
      #
      if iv.least < jv.least:
        return ok(Interval[P,S].new(iv.least, jv.least - scalarOne))
      # otherwise empty set => error

    elif iv.last < jv.least:
      #
      #  iv:    [--------]
      #  jv:              [------------]
      #
      return ok(iv)

    else: # so jv.least <= iv.last and jv.last < iv.last
      #
      #  iv:    [--------------]
      #  jv:          [------]
      #
      discard # error

  else: # jv.least < iv.least
    if iv.least <= jv.last and jv.last <= iv.last:
      #
      #  iv:          [------------]
      #  jv:    [--------------]
      #
      if jv.last < iv.last:
        return ok(Interval[P,S].new(jv.last + scalarOne, iv.last))
      # otherwise empty set => error

    elif jv.last < iv.least:
      #
      #  iv:              [------------]
      #  jv:    [--------]
      #
      return ok(iv)

    else: # so iv.least <= jv.last and iv.last < jv.last
      #
      #  iv:          [------]
      #  jv:    [--------------]
      #
      discard # error

  err()

proc `-`*[P,S](iv: IntervalRc[P,S]; jv: Interval[P,S]): IntervalRc[P,S] =
  ## Variant of `-`
  if iv.isOk:
    return iv.value - jv
  err()

proc `-`*[P,S](iv: Interval[P,S]; jv: IntervalRc[P,S]): IntervalRc[P,S] =
  ## Variant of `-`
  if jv.isOk:
    return iv - jv.value
  err()

proc `-`*[P,S](iv, jv: IntervalRc[P,S]): IntervalRc[P,S] =
  ## Variant of `-`
  if iv.isOk and jv.isOk:
    return iv.value - jv.valu
  err()

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc len*[P,S](iv: Interval[P,S]): S =
  ## Cardinality (ie. length) of argument interval `iv`. If the argument
  ## interval `iv` is `[low(P),high(P)]`, the return value will be the scalar
  ## *zero* (there are no empty intervals in this implementation.)
  if low(P) == iv.least and high(P) == iv.last:
    scalarZero
  else:
    (iv.last - iv.least) + scalarOne

proc minPt*[P,S](iv: Interval[P,S]): P =
  ## Left end, smallest point of `P` contained in the interval
  iv.least

proc maxPt*[P,S](iv: Interval[P,S]): P =
  ## Right end, largest point of `P` contained in the interval
  iv.last

proc total*[P,S](ds: IntervalSetRef[P,S]): S =
  ## Accumulated size covered by intervals in the interval set `ds`.
  ##
  ## In the special case when there is only the single interval
  ## `[low(P),high(P)]` in the interval set, the return value will be the
  ## scalar *zero* (there are no empty intervals in this implementation.)
  if not ds.lastHigh:
    ds.ptsCount
  elif maxSegmSize <= ds.ptsCount:
    scalarZero
  else:
    ds.ptsCount + scalarOne

proc chunks*[P,S](ds: IntervalSetRef[P,S]): int =
  ## Number of disjunkt intervals (aka chunks) in the interval set `ds`.
  result = ds.leftPos.len
  if ds.lastHigh:
    # check for isolated interval [high(P),high(P)]
    if result == 0 or ds.leftPos.le(high(P)).value.right < high(P):
      result.inc

# ------------------------------------------------------------------------------
# Public debugging functions
# ------------------------------------------------------------------------------

proc `$`*[P,S](p: DataRef[P,S]): string =
  ## Needed by `ds.verify()` for printing error messages
  "[" & $p.left & "," & $p.right & ")"

proc verify*[P,S](
    ds: IntervalSetRef[P,S]
      ): Result[void,(RbInfo,IntervalSetError)] =
  ## Verifyn interval set data structure
  try:
    let rc = ds.leftPos.verify
    if rc.isErr:
      return err((rc.error[1],isNoError))
  except CatchableError as e:
    raiseAssert $e.name & ": " & e.msg

  block:
    var
      count = scalarZero
      maxPt: P
      first = true
    for iv in ds.increasing:
      noisy.say "***", "verify(fwd)", " maxPt=", maxPt, " iv=", iv.pp
      if not(low(P) <= iv.least and iv.least <= iv.last and iv.last <= high(P)):
        noisy.say "***", "verify(fwd)", " error=", isErrorBogusInterval
        return err((rbOk,isErrorBogusInterval))
      if first:
        first = false
      elif iv.least <= maxPt:
        noisy.say "***", "verify(fwd)", " error=", isErrorOverlapping
        return err((rbOk,isErrorOverlapping))
      elif iv.least <= maxPt + scalarOne:
        noisy.say "***", "verify(fwd)", " error=", isErrorAdjacent
        return err((rbOk,isErrorAdjacent))
      maxPt = iv.last
      if iv.least == low(P) and iv.last == high(P):
        count += high(P) - low(P)
      else:
        count += iv.len

    if count != ds.ptsCount:
      noisy.say "***", "verify(fwd)",
        " error=", isErrorTotalMismatch,
        " count=", ds.ptsCount,
        " expected=", count
      return err((rbOk,isErrorTotalMismatch))

  block:
    var
      count = scalarZero
      minPt: P
      last = true
    for iv in ds.decreasing:
      #noisy.say "***", "verify(rev)", " minPt=", minPt, " iv=", iv.pp
      if not(low(P) <= iv.least and iv.least <= iv.last and iv.last <= high(P)):
        return err((rbOk,isErrorBogusInterval))
      if last:
        last = false
      elif minPt <= iv.least:
        return err((rbOk,isErrorOverlapping))
      elif minPt + scalarOne <= iv.least:
        return err((rbOk,isErrorAdjacent))
      minPt = iv.least
      if iv.least == low(P) and iv.last == high(P):
        count += high(P) - low(P)
      else:
        count += iv.len

    if count != ds.ptsCount:
      return err((rbOk,isErrorTotalMismatch))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

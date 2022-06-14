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

import
  chronicles,
  stint,
  stew/results,
  unittest2,
  ../nimbus/utils/interval_set

type
  FancyPoint = distinct UInt256              # instead of BlockNumber
  FancyRanges = IntervalSetRef[FancyPoint,UInt256]
  FancyInterval = Interval[FancyPoint,UInt256]

const
  uHigh = high(uint64)
  uLow = low(uint64)

let
  ivError = IntervalRc[FancyPoint,UInt256].err()

# ------------------------------------------------------------------------------
# Private data type interface
# ------------------------------------------------------------------------------

proc to(num: uint64; _: type FancyPoint): FancyPoint = num.u256.FancyPoint

# use a sub-range for `FancyPoint` elements
proc high(T: type FancyPoint): T = uHigh.to(FancyPoint)
proc low(T: type FancyPoint): T = uLow.to(FancyPoint)

proc u256(num: FancyPoint): UInt256 = num.UInt256
proc `$`(num: FancyPoint): string = $num.u256

proc `+`*(a: FancyPoint; b: UInt256): FancyPoint = (a.u256+b).FancyPoint
proc `-`*(a: FancyPoint; b: UInt256): FancyPoint = (a.u256-b).FancyPoint
proc `-`*(a, b: FancyPoint): UInt256 = (a.u256 - b.u256)

proc `==`*(a, b: FancyPoint): bool = a.u256 == b.u256
proc `<=`*(a, b: FancyPoint): bool = a.u256 <= b.u256
proc `<`*(a, b: FancyPoint): bool = a.u256 < b.u256

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc truncate(num: FancyPoint; T: type uint64): uint64 =
  num.u256.truncate(uint64)

proc merge(br: FancyRanges; left, right: uint64): uint64 =
  let (a, b) = (left.to(FancyPoint), right.to(FancyPoint))
  br.merge(a, b).truncate(uint64)

proc reduce(br: FancyRanges; left, right: uint64): uint64 =
  let (a, b) = (left.to(FancyPoint), right.to(FancyPoint))
  br.reduce(a, b).truncate(uint64)

proc covered(br: FancyRanges; left, right: uint64): uint64 =
  let (a, b) = (left.to(FancyPoint), right.to(FancyPoint))
  br.covered(a, b).truncate(uint64)

proc delete(br: FancyRanges; start: uint64): Result[FancyInterval,void] =
  br.delete(start.to(FancyPoint))

proc le(br: FancyRanges; start: uint64): Result[FancyInterval,void] =
  br.le(start.to(FancyPoint))

proc ge(br: FancyRanges; start: uint64): Result[FancyInterval,void] =
  br.ge(start.to(FancyPoint))

proc iv(left, right: uint64): FancyInterval =
  FancyInterval.new(left.to(FancyPoint), right.to(FancyPoint))

proc setTraceLevel* =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setErrorLevel* =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Test Runner
# ------------------------------------------------------------------------------

proc intervalSetRunner(noisy = true) =

  suite "IntervalSet: Intervals of FancyPoint entries over UInt256":
    let br = FancyRanges.init()
    var dup: FancyRanges

    test "Verify max interval handling":
      br.clear()
      check br.merge(0,uHigh) == 0
      check br.chunks == 1
      check br.total == 0
      check br.verify.isOk

      check br.reduce(uHigh,uHigh) == 1
      check br.chunks == 1
      check br.total == uHigh.u256
      check br.verify.isOk

    test "Verify handling of maximal interval points (edge cases)":
      br.clear()
      check br.merge(0,uHigh) == 0
      check br.reduce(uHigh-1,uHigh-1) == 1
      check br.verify.isOk
      check br.chunks == 2
      check br.total == uHigh.u256

      check br.le(uHigh) == iv(uHigh,uHigh)
      check br.le(uHigh-1) == iv(0,uHigh-2)
      check br.le(uHigh-2) == iv(0,uHigh-2)
      check br.le(uHigh-3) == ivError

      check br.ge(0) == iv(0,uHigh-2)
      check br.ge(1) == iv(uHigh,uHigh)
      check br.ge(uHigh-3) == iv(uHigh,uHigh)
      check br.ge(uHigh-2) == iv(uHigh,uHigh)
      check br.ge(uHigh-3) == iv(uHigh,uHigh)
      check br.ge(uHigh) == iv(uHigh,uHigh)

      check br.reduce(0,uHigh-2) == uHigh-1
      check br.verify.isOk
      check br.chunks == 1
      check br.total == 1.u256

      check br.le(uHigh) == iv(uHigh,uHigh)
      check br.le(uHigh-1) == ivError
      check br.le(uHigh-2) == ivError
      check br.le(0) == ivError

      check br.ge(uHigh) == iv(uHigh,uHigh)
      check br.ge(uHigh-1) == iv(uHigh,uHigh)
      check br.ge(uHigh-2) == iv(uHigh,uHigh)
      check br.ge(0) == iv(uHigh,uHigh)

      br.clear()
      check br.total == 0 and br.chunks == 0
      check br.merge(0,uHigh) == 0
      check br.reduce(0,9999999) == 10000000
      check br.total.truncate(uint64) == (uHigh - 10000000) + 1
      check br.verify.isOk

      check br.merge(uHigh,uHigh) == 0
      check br.verify.isOk

      check br.reduce(uHigh,uHigh-1) == 1 # same as reduce(uHigh,uHigh)
      check br.total.truncate(uint64) == (uHigh - 10000000)
      check br.verify.isOk
      check br.merge(uHigh,uHigh-1) == 1 # same as merge(uHigh,uHigh)
      check br.total.truncate(uint64) == (uHigh - 10000000) + 1
      check br.verify.isOk

      #interval_set.noisy = true
      #interval_set.noisy = false

    test "Merge disjunct intervals on 1st set":
      br.clear()
      check br.merge(  0,  99) == 100
      check br.merge(200, 299) == 100
      check br.merge(400, 499) == 100
      check br.merge(600, 699) == 100
      check br.merge(800, 899) == 100
      check br.total == 500
      check br.chunks == 5
      check br.verify.isOk

    test "Reduce non overlapping intervals on 1st set":
      check br.reduce(100, 199) == 0
      check br.reduce(300, 399) == 0
      check br.reduce(500, 599) == 0
      check br.reduce(700, 799) == 0
      check br.verify.isOk

    test "Clone a 2nd set and verify covered data ranges":
      dup = br.clone
      check dup.covered(  0,  99) == 100
      check dup.covered(100, 199) == 0
      check dup.covered(200, 299) == 100
      check dup.covered(300, 399) == 0
      check dup.covered(400, 499) == 100
      check dup.covered(500, 599) == 0
      check dup.covered(600, 699) == 100
      check dup.covered(700, 799) == 0
      check dup.covered(800, 899) == 100
      check dup.covered(900, uint64.high) == 0

      check dup.covered(200, 599) == 200
      check dup.covered(200, 799) == 300
      check dup.total == 500
      check dup.chunks == 5
      check dup.verify.isOk

    test "Merge overlapping intervals on 2nd set":
      check dup.merge( 50, 250) == 100
      check dup.merge(450, 850) == 200
      check dup.verify.isOk

    test "Verify covered data ranges on 2nd set":
      check dup.covered(  0, 299) == 300
      check dup.covered(300, 399) == 0
      check dup.covered(400, 899) == 500
      check dup.covered(900, uint64.high) == 0
      check dup.total == 800
      check dup.chunks == 2
      check dup.verify.isOk

    test "Verify 1st and 2nd set differ":
      check br != dup

    test "Reduce overlapping intervals on 2nd set":
      check dup.reduce(100, 199) == 100
      check dup.reduce(500, 599) == 100
      check dup.reduce(700, 799) == 100
      # interval_set.noisy = true
      check dup.verify.isOk

    test "Verify 1st and 2nd set equal":
      check br == dup
      check br == br
      check dup == dup

    test "Find intervals in the 1st set":
      check br.le(100) == iv(  0,  99)
      check br.le(199) == iv(  0,  99)
      check br.le(200) == iv(  0,  99)
      check br.le(299) == iv(200, 299)
      check br.le(999) == iv(800, 899)
      check br.le(50) == ivError

      check br.ge(  0) == iv(  0,  99)
      check br.ge(  1) == iv(200, 299)
      check br.ge(800) == iv(800, 899)
      check br.ge(801) == ivError

    test "Delete intervals from the 2nd set":
      check dup.delete(200) == iv(200, 299)
      check dup.delete(800) == iv(800, 899)
      check dup.verify.isOk

    test "Interval intersections":
      check iv(100, 199) * iv(150, 249) == iv(150, 199)
      check iv(150, 249) * iv(100, 199) == iv(150, 199)

      check iv(100, 199) * iv(200, 299) == ivError
      check iv(200, 299) * iv(100, 199) == ivError

      check iv(200, uHigh) * iv(uHigh,uHigh) == iv(uHigh,uHigh)
      check iv(uHigh, uHigh) * iv(200,uHigh) == iv(uHigh,uHigh)

      check iv(100, 199) * iv(150, 249) * iv(100, 170) == iv(150, 170)
      check (iv(100, 199) * iv(150, 249)) * iv(100, 170) == iv(150, 170)
      check iv(100, 199) * (iv(150, 249) * iv(100, 170)) == iv(150, 170)

    test "Join intervals":
      check iv(100, 199) + iv(150, 249) == iv(100, 249)
      check iv(150, 249) + iv(100, 199) == iv(100, 249)

      check iv(100, 198) + iv(202, 299) == ivError
      check iv(100, 199) + iv(200, 299) == iv(100, 299)
      check iv(100, 200) + iv(200, 299) == iv(100, 299)
      check iv(100, 201) + iv(200, 299) == iv(100, 299)

      check iv(200, 299) + iv(100, 198) == ivError
      check iv(200, 299) + iv(100, 199) == iv(100, 299)
      check iv(200, 299) + iv(100, 200) == iv(100, 299)
      check iv(200, 299) + iv(100, 201) == iv(100, 299)

      check iv(200, uHigh) + iv(uHigh,uHigh) == iv(200,uHigh)
      check iv(uHigh, uHigh) + iv(200,uHigh) == iv(200,uHigh)

      check iv(150, 249) + iv(100, 149) + iv(200, 299) == iv(100, 299)
      check (iv(150, 249) + iv(100, 149)) + iv(200, 299) == iv(100, 299)
      check iv(150, 249) + (iv(100, 149) + iv(200, 299)) == ivError

    test "Cut off intervals by other intervals":
      check iv(100, 199) - iv(150, 249) == iv(100, 149)
      check iv(150, 249) - iv(100, 199) == iv(200, 249)
      check iv(100, 199) - iv(200, 299) == iv(100, 199)
      check iv(200, 299) - iv(100, 199) == iv(200, 299)

      check iv(200, 399) - iv(250, 349) == ivError
      check iv(200, 299) - iv(200, 299) == ivError
      check iv(200, 299) - iv(200, 399) == ivError
      check iv(200, 299) - iv(100, 299) == ivError
      check iv(200, 299) - iv(100, 399) == ivError

      check iv(200, 299) - iv(100, 199) - iv(150, 249) == iv(250, 299)
      check (iv(200, 299) - iv(100, 199)) - iv(150, 249) == iv(250, 299)
      check iv(200, 299) - (iv(100, 199) - iv(150, 249)) == iv(200, 299)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc intervalSetMain*(noisy = defined(debug)) =
  noisy.intervalSetRunner

when isMainModule:
  let noisy = defined(debug) or true
  setTraceLevel()
  noisy.intervalSetRunner

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

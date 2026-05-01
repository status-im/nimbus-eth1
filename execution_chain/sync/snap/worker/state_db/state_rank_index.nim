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
  pkg/[eth/common, stew/interval_set],
  ../helpers

type
  StateRankIndex* = object
    unprocTotal: UInt256
    blockNumber: BlockNumber

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func toStr*(inx: StateRankIndex): string =
  var s = "("
  if inx.unprocTotal.isZero:
    s &= "0"
  elif inx.unprocTotal == high(UInt256):
    s &= "1"
  else:
    s &= inx.unprocTotal.per256.pcStr
  s & "," & $inx.blockNumber & ")"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func low*[T: StateRankIndex](_: type T): T =
  T(unprocTotal: low(UInt256), blockNumber: BlockNumber(high uint64))

func high*[T: StateRankIndex](_: type T): T =
  T(unprocTotal: high(UInt256), blockNumber: BlockNumber(0))

func to*[T: StateRankIndex](pair: (Opt[UInt256],BlockNumber), _: type T): T =
  ## Convert the argument `pair` to a type `StateRankIndex`.
  ##
  ## When mapping the argument `pair[0]` with value `Opt[UInt256]` into
  ## `UInt256`, it is interpreted as an interval range. So
  ## * `Opt.none(UInt256)` is mapped to `low(UInt256)` (aka `0`.)
  ## * `Opt.some(0.u256)` is mapped to `high(UInt256)` (aka `2^256-1`.)
  ## * all other values `Opt.some(w)` are mapped to `w`.
  ##
  ## So both vaues `Opt.some(0.u256)` and ``Opt.some(high UInt256)` have the
  ## same image `high(UInt256)`.
  ##
  T(unprocTotal: (if pair[0].isNone: 0.u256
                  elif pair[0].value.isZero: high UInt256
                  else: pair[0].value),
    blockNumber: pair[1])

func cmp*(x, y: StateRankIndex): int =
  ## `x < y` =>
  ##  * `x.unprocTotal < y.unprocTotal` or
  ##  * `x.unprocTotal == y.unprocTotal` and `y.blockNumber < x.blockNumber`
  ##
  var a = cmp(x.unprocTotal, y.unprocTotal)
  if a == 0:
    a = cmp(y.blockNumber, x.blockNumber)
  a

func total*(w: StateRankIndex): UInt256 =
  ## Getter
  w.unprocTotal

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

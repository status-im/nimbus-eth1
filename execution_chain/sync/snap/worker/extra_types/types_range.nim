# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module provides a `Hash32` isomorphism to a scalar space with
## arithmetic basics and some interval list functionality. This data
## type is used for
##
## * accounts and account ranges
## * storage slots and slot ranges
##

{.push raises:[].}

import
  std/[fenv, math, hashes, sequtils],
  pkg/[eth/common, eth/trie/nibbles, stint, stew/interval_set]

type
  PadMode* = enum
    padMin = 0u8
    padMax = 255u8

  ItemKey* = distinct UInt256
    ## Account trie item key, hash etc. as a scalar (allows arithmetic)

  ItemKeyRangeSet* = IntervalSetRef[ItemKey,UInt256]
    ## Disjunct sets of item keys (e.g. account/storage hashes(

  ItemKeyRange* = Interval[ItemKey,UInt256]
    ## Single interval of item keys (e.g. account/storage hashes(

# const
#   ItemKeyRangeMax => defined below

# ------------------------------------------------------------------------------
# Public `tables` support
# ------------------------------------------------------------------------------

func hash*(w: ItemKey): Hash = w.UInt256.hash

# ------------------------------------------------------------------------------
# Public `ItemKey` / `Hash32` interoperability
# ------------------------------------------------------------------------------

template to*[T: UInt256](w: ItemKey; _: type T): T = w.T
template to*[T: ItemKey](w: UInt256; _: type T): T = w.T

template to*[T: Hash32](w: ItemKey; _: type T): T = w.UInt256.to(Bytes32).T
template to*[T: UInt256](w: Hash32; _: type T): T = w.Bytes32.to(T)
template to*[T: ItemKey](w: Hash32; _: type T): T = w.to(UInt256).T
template to*[T: ItemKey](w: SomeUnsignedInt; _: type T): T = w.to(UInt256).T
template to*[T: ItemKey](w: Bytes32; _: type T): T = w.to(UInt256).T

template to*[T: ItemKey](w: array[32,byte]; _: type T): T =
  ## Handy for converting the result of `nibbles.getBytes()`
  w.Bytes32.to(UInt256).T

template to*[T: Hash32](w: seq[ItemKey], _: type seq[T]): seq[T] =
  ## No shortcut here (e.g. `cast[]()`) as there are different representations
  ## of the same data.
  w.mapIt(it.to(T))

template to*[T: ItemKey](w: seq[Hash32], _: type seq[T]): seq[T] =
  ## Dito
  w.mapIt(it.to(T))

proc fromNibbles*[T: ItemKey](_: type T, pfx: NibblesBuf, pad: PadMode): T =
  ## The function extend nibbles argument `pfx` to an `ItemKey`. It returns
  ## the eqivalent of `pfx & padding` where padding is an all zero nibbles
  ## sequence if the argument `pad` is `padMin`, and all `f` if `pad` is
  ## `padMax`.
  ##
  case pad:
  of padMin:
    pfx.getBytes.to(ItemKey)
  of padMax:
    const ffff = NibblesBuf.fromBytes 255u8.repeat(32)
    # Nibbles buf is 32 bytes, excess values will be ignored
    (pfx & ffff).getBytes.to(ItemKey)

proc fromNibbles*[T: ItemKeyRange](_: type T, pfx: NibblesBuf): T =
  if pfx.len < 64:
    const
      # Nibbles buf is 32 bytes. Any excess values will be ignored when
      # applying `ffff`
      ffff = NibblesBuf.fromBytes 255u8.repeat(32)
    let
      minPt = pfx.getBytes.to(ItemKey)
      maxPt = (pfx & ffff).getBytes.to(ItemKey)
    return ItemKeyRange.new(minPt, maxPt)

  let pt = pfx.getBytes.to(ItemKey)
  ItemKeyRange.new(pt, pt)

# ------------------------------------------------------------------------------
# Public `ItemKey` base arithmetic
# ------------------------------------------------------------------------------

func low*(T: type ItemKey): T = low(UInt256).T
func high*(T: type ItemKey): T = high(UInt256).T

func `+`*(a: ItemKey; b: UInt256): ItemKey = (a.UInt256 + b).ItemKey
func `-`*(a: ItemKey; b: UInt256): ItemKey = (a.UInt256 - b).ItemKey
func `-`*(a, b: ItemKey): UInt256 = a.UInt256 - b.UInt256

func `==`*(a, b: ItemKey): bool = a.UInt256 == b.UInt256
func `<=`*(a, b: ItemKey): bool = a.UInt256 <= b.UInt256
func `<`*(a, b: ItemKey): bool = a.UInt256 < b.UInt256

func cmp*(x, y: ItemKey): int = cmp(x.UInt256, y.UInt256)


func `+`*(a: ItemKey; b: SomeUnsignedInt): ItemKey = a + b.to(UInt256)
func `+`*(a: ItemKey; b: static[SomeSignedInt]): ItemKey =
  ## Convenience function, typically used with `1` (avoids `1u`)
  when 0 < b: a + b.uint64 elif b < 0: a - (-b).uint64 else: 0

func `-`*(a: ItemKey; b: SomeUnsignedInt): ItemKey = a - b.to(UInt256)
func `-`*(a: ItemKey; b: static[SomeSignedInt]): ItemKey = a + (-b)

const
  ItemKeyRangeMax* = ItemKeyRange.new(low(ItemKey),high(ItemKey))

# ------------------------------------------------------------------------------
# Other public helpers
# ------------------------------------------------------------------------------

func to*(w: ItemKey; _: type float): float =
  w.UInt256.to(float)

func to*(w: (ItemKey,ItemKey); _: type float): (float,float) =
  (w[0].to(float), w[1].to(float))

func to*(w: ItemKeyRange; _: type float): (float,float) =
  (w.minPt, w.maxPt).to(float)

func to*(w: UInt256; _: type float): float =
  ## Lossy conversion to `float`
  ##
  when sizeof(float) != sizeof(uint):
    {.error: "Expected float having the same size as uint".}
  let mantissa = 256 - w.leadingZeros
  if mantissa <= mantissaDigits(float):             # `<= 53` on a 64 bit system
    return w.truncate(uint).float
  # Calculate `w / 2^exp * 2^exp` = `w`
  let exp = mantissa - mantissaDigits(float)        # is positive
  (w shr exp).truncate(uint).float * 2f.pow(exp.float)

# ------------------------------------------------------------------------------
# Functions extending the `ItemKeyRange` basic functionality
# ------------------------------------------------------------------------------

proc fetchLeast*(ikrs: ItemKeyRangeSet; maxLen: UInt256): Opt[ItemKeyRange] =
  ## Borrowed from `unproc_item_keys.nim` for a single `ItemKeyRangeSet`
  ## (w/o the `borrowed` part.)
  ##
  let
    jv = ikrs.ge().valueOr:
      return err()
    kv = block:
      if maxLen.isZero or (jv.len.isZero.not and jv.len <= maxLen):
        jv
      else:
        ItemKeyRange.new(jv.minPt, jv.minPt + (maxLen - 1.u256))

  discard ikrs.reduce(kv)
  ok(kv)

func per256*(w: UInt256): float =
  ## Represents the quotiont `w / 2^256` as `float` value. Note that the
  ## result is non-negaive and always smaller than `1f`.
  ##
  when sizeof(float) != sizeof(uint):
    {.error: "Expected float having the same size as uint".}
  if w.isZero:
    return 0f
  let mantissa = 256 - w.leadingZeros
  if mantissa <= mantissaDigits(float):             # `<= 53` on a 64 bit system
    return w.truncate(uint).float / 2f.pow(256.float)
  # Calculate `total / 2^exp / 2^(256-exp)` = `total / 2^256`
  let exp = mantissa - mantissaDigits(float)        # is positive
  (w shr exp).truncate(uint).float / 2f.pow((256 - exp).float)

func per256*(w: Opt[UInt256]): float =
  ## Variant of `per256()` where the argument `w` covers the full scalar
  ## range with `Opt.none()` repesenting `0` and `Opt.some(0)` representing
  ## `2^255` (where the latter is not in the scalar range for `UInt256`,
  ## anymore.)
  ##
  if w.isNone: 0f
  elif w.value.isZero: 1f
  else: w.value.per256()

func totalRatio*(ikrs: ItemKeyRangeSet): float =
  ## Borrowed from `unproc_item_keys.nim` for a single `ItemKeyRangeSet`
  ## (w/o the `borrowed` part.)
  ##
  let total = ikrs.total()
  if total.isZero:
    return (if ikrs.chunks() == 0: 0f else: 1f)
  total.per256()

# -------------------

proc init*(T: type ItemKeyRangeSet, ivInit: ItemKeyRange): T =
  ## Some shortcut
  let ikrs = ItemKeyRangeSet.init()
  discard ikrs.merge ivInit
  ikrs

func complement*(ikrs: ItemKeyRangeSet): ItemKeyRangeSet =
  ## Missing functionality from `interval_set` API.
  result = ItemKeyRangeSet.init ItemKeyRangeMax
  for iv in ikrs.increasing:
    discard result.reduce iv

func covered*(ikrs: ItemKeyRangeSet, pt: ItemKey): bool =
  ## Missing functionality from `interval_set` API.
  0 < ikrs.covered(pt, pt)

func `+=`*(a, b: ItemKeyRangeSet) =
  ## Missing functionality from `interval_set` API.
  for iv in b.increasing:
    discard a.merge iv

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

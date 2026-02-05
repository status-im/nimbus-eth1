# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module provides a `Hash32` mapping into a scalar space with some
## arithmetic basics and some interval list functionality.
##

{.push raises:[].}

import
  std/[fenv, math],
  pkg/[eth/common, stint, stew/interval_set],
  ../helpers

type
  ItemKey* = distinct UInt256
    ## Account trie item key, hash etc. as a scalar (allows arithmetic)

  ItemKeyRangeSet* = IntervalSetRef[ItemKey,UInt256]
    ## Disjunct sets of item keys (e.g. account/storage hashes(

  ItemKeyRange* = Interval[ItemKey,UInt256]
    ## Single interval of item keys (e.g. account/storage hashes(

# ------------------------------------------------------------------------------
# Public `ItemKey` / `Hash32` interoperability
# ------------------------------------------------------------------------------

template to*(w: ItemKey; T: type UInt256): T = w.T
template to*(w: UInt256; T: type ItemKey): T = w.T

template to*(w: ItemKey; T: type Hash32): T = w.UInt256.to(Bytes32).T
template to*(w: Hash32; T: type UInt256): T = w.Bytes32.to(T)
template to*(w: Hash32; T: type ItemKey): T = w.to(UInt256).T

template to*(w: SomeUnsignedInt; T: type ItemKey): T = w.to(UInt256).T

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
# Public print functions
# ------------------------------------------------------------------------------

func toStr*(w: ItemKey): string =
  if w == high(ItemKey): "n/a" else: $(w.to(UInt256))

func toStr*(w: (ItemKey,ItemKey)): string =
  func xStr(w: ItemKey): string =
    if w == high(ItemKey): "high(ItemKey)" else: $(w.to(UInt256))
  if w[0] < w[1]: $(w[0].to(UInt256)) & ".." & w[1].xStr
  elif w[0] == w[1]: w[0].xStr
  else: "n/a"

func toStr*(w: ItemKeyRange): string =
  (w.minPt,w.maxPt).toStr


func `$`*(w: ItemKey|ItemKeyRange): string =
  w.toStr

# ------------------------------------------------------------------------------
# Other public helpers
# ------------------------------------------------------------------------------

func to*(w: UInt256; T: type float): T =
  ## Lossy conversion to `float` -- great for printing
  ##
  when sizeof(float) != sizeof(uint):
    {.error: "Expected float having the same size as uint".}
  let mantissa = 256 - w.leadingZeros
  if mantissa <= mantissaDigits(float):         # `<= 53` on a 64 bit system
    return w.truncate(uint).float
  # Calculate `w / 2^exp * 2^exp` = `w`
  let exp = mantissa - mantissaDigits(float)
  (w shr exp).truncate(uint).float * 2f.pow(exp.float)

func to*(w: ItemKey; _: type float): float =
  w.UInt256.to(float)

func to*(w: (ItemKey,ItemKey); _: type float): (float,float) =
  (w[0].to(float), w[1].to(float))

func to*(w: ItemKeyRange; _: type float): (float,float) =
  (w.minPt, w.maxPt).to(float)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

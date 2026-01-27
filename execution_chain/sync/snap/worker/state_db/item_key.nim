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
  std/math,
  pkg/[eth/common, stint, stew/interval_set]

export
  Hash32, stint, interval_set


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
# Other public helpers
# ------------------------------------------------------------------------------

func to*(w: UInt256; T: type float): T =
  ## Lossy conversion to `float` -- great for printing
  if w == high(UInt256):
    return Inf
  let mantissaLen = 256 - w.leadingZeros
  if mantissaLen <= 64:
    return w.truncate(uint64).T
  let exp = mantissaLen - 64
  (w shr exp).truncate(uint64).T * 2f.pow(exp.float)

func to*(w: ItemKey; _: type float): float =
  w.UInt256.to(float)

func to*(w: (ItemKey,ItemKey); _: type float): (float,float) =
  (w[0].to(float), w[1].to(float))

func to*(w: ItemKeyRange; _: type float): (float,float) =
  (w.minPt, w.maxPt).to(float)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

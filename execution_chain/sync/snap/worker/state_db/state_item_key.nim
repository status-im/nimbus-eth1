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
  std/hashes,
  pkg/[eth/common, stint, stew/interval_set],
  ../helpers

type
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

template to*(w: ItemKey; T: type UInt256): T = w.T
template to*(w: UInt256; T: type ItemKey): T = w.T

template to*(w: array[32,byte]; T: type ItemKey): T = w.Bytes32.to(UInt256).T
  ## Handy for converting the result of `desc_nibbles.getBytes()`

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

func flStr*(w: ItemKey): string =
  w.to(UInt256).flStr

func flStr*(w: (ItemKey,ItemKey)): string =
  (w[0].to(UInt256),w[1].to(UInt256)).flStr

func flStr*(w: ItemKeyRange): string =
  (w.minPt,w.maxPt).flStr

func lenStr*(w: (ItemKey,ItemKey)): string =
  (w[0].to(UInt256),w[1].to(UInt256)).lenStr

func lenStr*(w: ItemKeyRange): string =
  (w.minPt,w.maxPt).lenStr

func `$`*(w: ItemKey|ItemKeyRange): string =
  w.flStr

# ------------------------------------------------------------------------------
# Other public helpers
# ------------------------------------------------------------------------------

func to*(w: ItemKey; _: type float): float =
  w.UInt256.to(float)

func to*(w: (ItemKey,ItemKey); _: type float): (float,float) =
  (w[0].to(float), w[1].to(float))

func to*(w: ItemKeyRange; _: type float): (float,float) =
  (w.minPt, w.maxPt).to(float)

# ------------------------------------------------------------------------------
# Functions extending the `ItemKeyRange` basic functionality
# ------------------------------------------------------------------------------

proc init*(T: type ItemKeyRangeSet, ivInit: ItemKeyRange): T =
  ## Some shortcut
  let ikrs = ItemKeyRangeSet.init()
  discard ikrs.merge ivInit
  ikrs

proc fetchLeast*(ikrs: ItemKeyRangeSet; maxLen: UInt256): Opt[ItemKeyRange] =
  ## Borrowed from `unproc_item_keys.nim` for a single `ItemKeyRangeSet`
  ## (w/o the `borrowed` part.)
  ##
  let
    jv = ikrs.ge().valueOr:
      return err()
    kv = block:
      if maxLen == 0 or (jv.len != 0 and jv.len <= maxLen):
        jv
      else:
        ItemKeyRange.new(jv.minPt, jv.minPt + (maxLen - 1.u256))

  discard ikrs.reduce(kv)
  ok(kv)

func totalRatio*(ikrs: ItemKeyRangeSet): float =
  ## Borrowed from `unproc_item_keys.nim` for a single `ItemKeyRangeSet`
  ## (w/o the `borrowed` part.)
  ##
  let total = ikrs.total()
  if total == 0:
    return (if ikrs.chunks() == 0: 0f else: 1f)
  total.per256()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

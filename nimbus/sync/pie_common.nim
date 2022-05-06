# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[sets, tables, sequtils, strutils],
  chronos, stint,
  eth/[common/eth_types, rlp, p2p],
  "."/[sync_types]

type
  LeafRange* = object
    leafLow*, leafHigh*:    LeafPath

  SharedFetchState* = ref object of typeof SyncPeer().sharedFetchBase
    ## Account fetching state that is shared among all peers.
    # Leaf path ranges not fetched or in progress on any peer.
    leafRanges:             seq[LeafRange]
    countAccounts*:         int64
    countAccountBytes*:     int64
    countRange*:            UInt256
    countRangeStarted*:     bool
    countRangeSnap*:        UInt256
    countRangeSnapStarted*: bool
    countRangeTrie*:        UInt256
    countRangeTrieStarted*: bool
    displayTimer:           TimerCallback

template sharedFetch*(sp: SyncPeer): auto =
  sync_types.sharedFetchBase(sp).SharedFetchState

proc rangeFraction(value: UInt256, discriminator: bool): int =
  ## Format a value in the range 0..2^256 as a percentage, 0-100%.  As the
  ## top of the range 2^256 cannot be represented in `UInt256` it actually
  ## has the value `0: UInt256`, and with that value, `discriminator` is
  ## consulted to decide between 0% and 100%.  For other values, the value is
  ## constrained to be between slightly above 0% and slightly below 100%,
  ## so that the endpoints are distinctive when displayed.
  const multiplier = 10000
  var fraction: int = 0 # Fixed point, fraction 0.0-1.0 multiplied up.
  if value == 0:
    return if discriminator: multiplier else: 0 # Either 100.00% or 0.00%.

  const shift = 8 * (sizeof(value) - sizeof(uint64))
  const wordHigh: uint64 = (high(typeof(value)) shr shift).truncate(uint64)
  # Divide `wordHigh+1` by `multiplier`, rounding up, avoiding overflow.
  const wordDiv: uint64 = 1 + ((wordHigh shr 1) div (multiplier.uint64 shr 1))
  let wordValue: uint64 = (value shr shift).truncate(uint64)
  let divided: uint64 = wordValue div wordDiv
  return if divided >= multiplier: multiplier - 1
         elif divided <= 0: 1
         else: divided.int

proc percent(value: UInt256, discriminator: bool): string =
  var str = intToStr(rangeFraction(value, discriminator), 3)
  str.insert(".", str.len - 2)
  str.add('%')
  return str

proc setDisplayTimer(sp: SyncPeer, at: Moment) {.gcsafe.}

proc displayUpdate(sp: SyncPeer) {.gcsafe.} =
  let sharedFetch = sp.sharedFetch
  doAssert not sharedFetch.isNil

  info "State: Account sync progress",
    percent=percent(sharedFetch.countRange, sharedFetch.countRangeStarted),
    accounts=sharedFetch.countAccounts,
    snap=percent(sharedFetch.countRangeSnap, sharedFetch.countRangeSnapStarted),
    trie=percent(sharedFetch.countRangeTrie, sharedFetch.countRangeTrieStarted)
  sp.setDisplayTimer(Moment.fromNow(1.seconds))

proc setDisplayTimer(sp: SyncPeer, at: Moment) =
  sp.sharedFetch.displayTimer = safeSetTimer(at, displayUpdate, sp)

proc newSharedFetchState(sp: SyncPeer): SharedFetchState =
  result = SharedFetchState(
    leafRanges: @[LeafRange(leafLow: low(LeafPath), leafHigh: high(LeafPath))]
  )
  result.displayTimer = safeSetTimer(Moment.fromNow(100.milliseconds),
                                     displayUpdate, sp)

proc hasSlice*(sp: SyncPeer): bool =
  ## Return `true` iff `getSlice` would return a free slice to work on.
  if sp.sharedFetch.isNil:
    sp.sharedFetch = newSharedFetchState(sp)
  result = not sp.sharedFetch.isNil and sp.sharedFetch.leafRanges.len > 0
  trace "Sync: hasSlice", hasSlice=result, peer=sp

proc getSlice*(sp: SyncPeer, leafLow, leafHigh: var LeafPath): bool =
  ## Claim a free slice to work on.  If a slice was available, it's claimed,
  ## `leadLow` and `leafHigh` are set to the slice range and `true` is
  ## returned.  Otherwise `false` is returned.

  if sp.sharedFetch.isNil:
    sp.sharedFetch = newSharedFetchState(sp)
  let sharedFetch = sp.sharedFetch
  template ranges: auto = sharedFetch.leafRanges
  const leafMaxFetchRange = (high(LeafPath) - low(LeafPath)) div 1000

  if ranges.len == 0:
    trace "Sync: getSlice", leafRange="none"
    return false
  leafLow = ranges[0].leafLow
  if ranges[0].leafHigh - ranges[0].leafLow <= leafMaxFetchRange:
    leafHigh = ranges[0].leafHigh
    ranges.delete(0)
  else:
    leafHigh = leafLow + leafMaxFetchRange
    ranges[0].leafLow = leafHigh + 1
  trace "Sync: getSlice", leafRange=pathRange(leafLow, leafHigh), peer=sp
  return true

proc putSlice*(sp: SyncPeer, leafLow, leafHigh: LeafPath) =
  ## Return a slice to the free list, merging with the rest of the list.

  let sharedFetch = sp.sharedFetch
  template ranges: auto = sharedFetch.leafRanges

  trace "Sync: putSlice", leafRange=pathRange(leafLow, leafHigh), peer=sp
  var i = 0
  while i < ranges.len and leafLow > ranges[i].leafHigh:
    inc i
  if i > 0 and leafLow - 1 == ranges[i-1].leafHigh:
    dec i
  var j = i
  while j < ranges.len and leafHigh >= ranges[j].leafLow:
    inc j
  if j < ranges.len and leafHigh + 1 == ranges[j].leafLow:
    inc j
  if j == i:
    ranges.insert(LeafRange(leafLow: leafLow, leafHigh: leafHigh), i)
  else:
    if j-1 > i:
      ranges[i].leafHigh = ranges[j-1].leafHigh
      ranges.delete(i+1, j-1)
    if leafLow < ranges[i].leafLow:
      ranges[i].leafLow = leafLow
    if leafHigh > ranges[i].leafHigh:
      ranges[i].leafHigh = leafHigh

template getSlice*(sp: SyncPeer, leafRange: var LeafRange): bool =
  sp.getSlice(leafRange.leafLow, leafRange.leafHigh)

template putSlice*(sp: SyncPeer, leafRange: LeafRange) =
  sp.putSlice(leafRange.leafLow, leafRange.leafHigh)

proc countSlice*(sp: SyncPeer, leafLow, leafHigh: LeafPath, which: bool) =
  doAssert leafLow <= leafHigh
  sp.sharedFetch.countRange += leafHigh - leafLow + 1
  sp.sharedFetch.countRangeStarted = true
  if which:
    sp.sharedFetch.countRangeSnap += leafHigh - leafLow + 1
    sp.sharedFetch.countRangeSnapStarted = true
  else:
    sp.sharedFetch.countRangeTrie += leafHigh - leafLow + 1
    sp.sharedFetch.countRangeTrieStarted = true

template countSlice*(sp: SyncPeer, leafRange: LeafRange, which: bool) =
  sp.countSlice(leafRange.leafLow, leafRange.leafHigh, which)

proc countAccounts*(sp: SyncPeer, len: int) =
  sp.sharedFetch.countAccounts += len

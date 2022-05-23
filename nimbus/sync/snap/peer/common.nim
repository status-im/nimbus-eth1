# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[sets, sequtils, strutils],
  chronos,
  chronicles,
  eth/[common/eth_types, p2p],
  stint,
  ".."/[base_desc, path_desc],
  ./sync_xdesc

{.push raises: [Defect].}

logScope:
  topics = "snap peer common"

proc hasSlice*(sp: SnapPeer): bool =
  ## Return `true` iff `getSlice` would return a free slice to work on.
  if sp.nsx.sharedFetch.isNil:
    sp.nsx.sharedFetch = SharedFetchState.new
  result = 0 < sp.nsx.sharedFetch.leafRanges.len
  trace "hasSlice", peer=sp, hasSlice=result

proc getSlice*(sp: SnapPeer, leafLow, leafHigh: var LeafPath): bool =
  ## Claim a free slice to work on.  If a slice was available, it's claimed,
  ## `leadLow` and `leafHigh` are set to the slice range and `true` is
  ## returned.  Otherwise `false` is returned.

  if sp.nsx.sharedFetch.isNil:
    sp.nsx.sharedFetch = SharedFetchState.new
  let sharedFetch = sp.nsx.sharedFetch
  template ranges: auto = sharedFetch.leafRanges
  const leafMaxFetchRange = (high(LeafPath) - low(LeafPath)) div 1000

  if ranges.len == 0:
    trace "GetSlice", leafRange="none"
    return false
  leafLow = ranges[0].leafLow
  if ranges[0].leafHigh - ranges[0].leafLow <= leafMaxFetchRange:
    leafHigh = ranges[0].leafHigh
    ranges.delete(0)
  else:
    leafHigh = leafLow + leafMaxFetchRange
    ranges[0].leafLow = leafHigh + 1
  trace "GetSlice", peer=sp, leafRange=pathRange(leafLow, leafHigh)
  return true

proc putSlice*(sp: SnapPeer, leafLow, leafHigh: LeafPath) =
  ## Return a slice to the free list, merging with the rest of the list.

  let sharedFetch = sp.nsx.sharedFetch
  template ranges: auto = sharedFetch.leafRanges

  trace "PutSlice", leafRange=pathRange(leafLow, leafHigh), peer=sp
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

template getSlice*(sp: SnapPeer, leafRange: var LeafRange): bool =
  sp.getSlice(leafRange.leafLow, leafRange.leafHigh)

template putSlice*(sp: SnapPeer, leafRange: LeafRange) =
  sp.putSlice(leafRange.leafLow, leafRange.leafHigh)

proc countSlice*(sp: SnapPeer, leafLow, leafHigh: LeafPath, which: bool) =
  doAssert leafLow <= leafHigh
  sp.nsx.sharedFetch.countRange += leafHigh - leafLow + 1
  sp.nsx.sharedFetch.countRangeStarted = true
  if which:
    sp.nsx.sharedFetch.countRangeSnap += leafHigh - leafLow + 1
    sp.nsx.sharedFetch.countRangeSnapStarted = true
  else:
    sp.nsx.sharedFetch.countRangeTrie += leafHigh - leafLow + 1
    sp.nsx.sharedFetch.countRangeTrieStarted = true

template countSlice*(sp: SnapPeer, leafRange: LeafRange, which: bool) =
  sp.countSlice(leafRange.leafLow, leafRange.leafHigh, which)

proc countAccounts*(sp: SnapPeer, len: int) =
  sp.nsx.sharedFetch.countAccounts += len

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
  std/[sets, strutils],
  chronos,
  chronicles,
  eth/[common/eth_types, p2p],
  stint,
  ".."/[base_desc, path_desc, timer_helper]

{.push raises: [Defect].}

type
  SharedFetchState* = ref object
    ## Account fetching state that is shared among all peers.
    # Leaf path ranges not fetched or in progress on any peer.
    leafRanges*:            seq[LeafRange]
    countAccounts*:         int64
    countAccountBytes*:     int64
    countRange*:            UInt256
    countRangeStarted*:     bool
    countRangeSnap*:        UInt256
    countRangeSnapStarted*: bool
    countRangeTrie*:        UInt256
    countRangeTrieStarted*: bool
    logTicker:              TimerCallback

  SnapSyncEx* = ref object of SnapSyncBase
    sharedFetch*: SharedFetchState

# ------------------------------------------------------------------------------
# Private  timer helpers
# ------------------------------------------------------------------------------

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
  result = intToStr(rangeFraction(value, discriminator), 3)
  result.insert(".", result.len - 2)
  result.add('%')


proc setLogTicker(sf: SharedFetchState; at: Moment) {.gcsafe.}

proc runLogTicker(sf: SharedFetchState) {.gcsafe.} =
  doAssert not sf.isNil
  info "State: Account sync progress",
    percent = percent(sf.countRange, sf.countRangeStarted),
    accounts = sf.countAccounts,
    snap = percent(sf.countRangeSnap, sf.countRangeSnapStarted),
    trie = percent(sf.countRangeTrie, sf.countRangeTrieStarted)
  sf.setLogTicker(Moment.fromNow(1.seconds))

proc setLogTicker(sf: SharedFetchState; at: Moment) =
  sf.logTicker = safeSetTimer(at, runLogTicker, sf)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc new*(T: type SharedFetchState; startLoggingAfter = 100.milliseconds): T =
  result = SharedFetchState(
    leafRanges: @[LeafRange(
      leafLow: LeafPath.low,
      leafHigh: LeafPath.high)])
  result.logTicker = safeSetTimer(
    Moment.fromNow(startLoggingAfter),
    runLogTicker,
    result)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc nsx*[T](sp: T): SnapSyncEx =
  ## Handy helper, typically used with `T` instantiated as `SnapPeerEx`
  sp.ns.SnapSyncEx

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

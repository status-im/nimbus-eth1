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
  std/[math, sets, sequtils, strutils],
  chronos,
  chronicles,
  eth/[common/eth_types, p2p],
  stint,
  ../../../../utils/interval_set,
  ../../path_desc,
  ../worker_desc,
  ./timer_helper

{.push raises: [Defect].}

logScope:
  topics = "snap common"

type
  RangeCounter = object
    counted: UInt256
    started: bool

  AccountsStats = object
    counted: int64
    bytes: int64

  LeafRangeSet = ##\
    ## Internal shortcut
    IntervalSetRef[LeafItem,UInt256]

  FetchEx = ref object of FetchBase
    ## Account fetching state that is shared among all peers.
    # Leaf path ranges not fetched or in progress on any peer.
    leafRanges: LeafRangeSet
    accounts:   AccountsStats
    cRange:     RangeCounter
    cRangeSnap: RangeCounter
    cRangeTrie: RangeCounter
    logTicker:  TimerCallback

const
  defaultTickerStartDelay = 100.milliseconds
  tickerLogInterval = 1.seconds
  leafRangeMaxLen = (high(LeafItem) - low(LeafItem)) div 1000

# ------------------------------------------------------------------------------
# Private timer helpers
# ------------------------------------------------------------------------------

proc to(num: UInt256;T: type float): T =
  let mantissaLen = 256 - num.leadingZeros
  if mantissaLen <= 64:
    num.truncate(uint64).T
  else:
    let exp = mantissaLen - 64
    (num shr exp).truncate(uint64).T * (2.0 ^ exp)

proc percent(cc: RangeCounter): string =
  if cc.started:
    result = ((cc.counted.to(float)*10000 / (2.0^256)).int).intToStr(3) & "%"
    result.insert(".", result.len - 3)
  else:
    result = "n/a"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc setLogTicker(sf: FetchEx; at: Moment) {.gcsafe.}

proc runLogTicker(sf: FetchEx) {.gcsafe.} =
  doAssert not sf.isNil
  info "Sync accounts progress",
    accounts = sf.accounts.counted,
    snap = sf.cRangeSnap.percent,
    trie = sf.cRangeTrie.percent,
    both = sf.cRange.percent
  sf.setLogTicker(Moment.fromNow(tickerLogInterval))

proc setLogTicker(sf: FetchEx; at: Moment) =
  if sf.logTicker.isNil:
    debug "Sync accounts progress ticker has stopped"
  else:
    sf.logTicker = safeSetTimer(at, runLogTicker, sf)

proc init(T: type FetchEx; startAfter = defaultTickerStartDelay): T =
  result = FetchEx(
    leafRanges: LeafRangeSet.init())
  discard result.leafRanges.merge(low(LeafItem),high(LeafItem))
  result.logTicker = safeSetTimer(
    Moment.fromNow(startAfter),
    runLogTicker,
    result)

proc withMaxLen(iv: LeafRange): LeafRange =
  ## Reduce interval to maximal size
  if 0 < iv.len and iv.len < leafRangeMaxLen:
    # Note that `[0,high].len` is `0` (rather than `high+1`)
    iv
  else:
    LeafRange.new(iv.minPt, iv.minPt + (leafRangeMaxLen - 1).u256)

# ------------------------------------------------------------------------------
# Private getters
# ------------------------------------------------------------------------------

proc leafRanges(sp: WorkerBuddy): LeafRangeSet =
  ## Handy helper
  sp.ns.fetchBase.FetchEx.leafRanges

proc fetchEx(ns: Worker): FetchEx =
  ## Handy helper
  ns.fetchBase.FetchEx

# ------------------------------------------------------------------------------
# Private setters
# ------------------------------------------------------------------------------

proc `fetchEx=`(ns: Worker; value: FetchEx) =
  ## Handy helper
  ns.fetchBase = value

proc `+=`(cc: var RangeCounter; val: UInt256) =
  cc.counted += val # at most `leafRangeMaxLen`
  cc.started = true

# ------------------------------------------------------------------------------
# Public start/stop functions!
# ------------------------------------------------------------------------------

proc commonSetup*(ns: Worker) =
  ## Global set up
  discard

proc commonRelease*(ns: Worker) =
  ## Global clean up
  if not ns.fetchEx.isNil:
    ns.fetchEx.logTicker = nil # stop timer
    ns.fetchEx = nil           # unlink `CommonFetchEx` object

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasSlice*(sp: WorkerBuddy): bool =
  ## Return `true` iff `getSlice` would return a free slice to work on.
  if sp.ns.fetchEx.isNil:
    sp.ns.fetchEx = FetchEx.init()
  result = 0 < sp.leafRanges.chunks
  trace "hasSlice", peer=sp, hasSlice=result


proc getSlice*(sp: WorkerBuddy): Result[LeafRange,void] =
  ## Claim a free slice to work on, ie. remove the leftmost interval from
  ## the set of leaf ranges.
  if sp.ns.fetchEx.isNil:
    sp.ns.fetchEx = FetchEx.init()

  let rc = sp.leafRanges.ge()
  if rc.isErr:
    trace "getSlice()", leafRange="none"
    return err()

  let iv = rc.value.withMaxLen
  discard sp.leafRanges.reduce(iv.minPt, iv.maxPt)
  trace "getSlice()", peer=sp , leafRange=iv
  ok(iv)


proc putSlice*(sp: WorkerBuddy, iv: LeafRange) =
  discard sp.leafRanges.merge(iv.minPt, iv.maxPt)
  trace "putSlice()", peer=sp, leafRange=iv


proc countSnapSlice*(sp: WorkerBuddy; iv: LeafRange) =
  sp.ns.fetchEx.cRange += iv.len
  sp.ns.fetchEx.cRangeSnap += iv.len

proc countTrieSlice*(sp: WorkerBuddy; iv: LeafRange) =
  sp.ns.fetchEx.cRange += iv.len
  sp.ns.fetchEx.cRangeTrie += iv.len


proc accountsInc*(sp: WorkerBuddy; bytes: SomeInteger; nAcc = 1) =
  sp.ns.fetchEx.accounts.counted += nAcc
  sp.ns.fetchEx.accounts.bytes += bytes

proc accountsDec*(sp: WorkerBuddy; bytes: SomeInteger; nAcc:SomeInteger = 1) =
  sp.ns.fetchEx.accounts.counted -= nAcc
  sp.ns.fetchEx.accounts.bytes -= bytes

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

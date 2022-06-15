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
  chronos,
  chronicles,
  eth/[common/eth_types, p2p],
  stint,
  ../../../../utils/interval_set,
  ../../../types,
  ../../path_desc,
  ../worker_desc,
  ./timer_helper

{.push raises: [Defect].}

logScope:
  topics = "snap common"

type
  AccountsStats = object
    counted: int64
    bytes: int64

  LeafRangeSet = ##\
    ## Internal shortcut
    IntervalSetRef[LeafItem,UInt256]

  FetchEx = ref object of FetchBase
    ## Account fetching state that is shared among all peers.
    # Leaf path ranges not fetched or in progress on any peer.
    leafRanges:  LeafRangeSet
    accounts:    AccountsStats
    snapCounter: UInt256
    logTicker:   TimerCallback
    tick:        uint64 # 58494241735y when ticking 10 times a second

const
  defaultTickerStartDelay = 100.milliseconds
  tickerLogInterval = 1.seconds
  leafRangeMaxLen = (high(LeafItem) - low(LeafItem)) div 1000

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc setLogTicker(sf: FetchEx; at: Moment) {.gcsafe.}

proc runLogTicker(sf: FetchEx) {.gcsafe.} =
  info "Sync accounts progress",
    tick = sf.tick.toSI,
    accounts = sf.accounts.counted,
    snap = sf.snapCounter.toPc256
  sf.tick.inc
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
  sp.ns.fetchEx.snapCounter += iv.len

proc countAccounts*(sp: WorkerBuddy; bytes: SomeInteger; nAcc = 1) =
  sp.ns.fetchEx.accounts.counted += nAcc
  sp.ns.fetchEx.accounts.bytes += bytes

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

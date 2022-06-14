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
  eth/[common/eth_types, p2p],
  nimcrypto/keccak,
  stew/keyed_queue,
  stint,
  ../../../utils/interval_set,
  ../../types,
  ../path_desc,
  ./fetch/fetch_accounts,
  "."/[ticker, worker_desc]

{.push raises: [Defect].}

type
  FetchEx = ref object of WorkerFetchBase
    accTab: AccLruCache             ## Global worker data
    quCount: uint64                 ## Count visited roots

  AccTabEntryRef = ref object
    ## Global worker table
    avail: LeafRangeSet             ## Accounts to visit (organised as ranges)
    pivot: LeafItem                 ## where to to start fetching from

  AccLruCache =
    KeyedQueue[TrieHash,AccTabEntryRef]

logScope:
  topics = "snap-fetch"

const
  accRangeMaxLen = (high(LeafItem) - low(LeafItem)) div 1000

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc withMaxLen(iv: LeafRange): LeafRange =
  ## Reduce accounts interval to maximal size
  if 0 < iv.len and iv.len < accRangeMaxLen:
    iv
  else:
    LeafRange.new(iv.minPt, iv.minPt + (accRangeMaxLen - 1).u256)

proc fetchEx(ns: Worker): FetchEx =
  ## Getter
  ns.fetchBase.FetchEx

proc fetchEx(sp: WorkerBuddy): FetchEx =
  ## Getter
  sp.ns.fetchEx

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getAccTab(sp: WorkerBuddy; key: TrieHash): AccTabEntryRef =
  ## Fetch LRU table item, create a new one if missing.
  # fetch existing table (if any)
  block:
    let rc = sp.ns.fetchEx.accTab.lruFetch(key)
    if rc.isOk:
      # Item was moved to the end of queue
      return rc.value

  # Calculate some new start address for the range fetcher
  var start: LeafItem
  while true:
    # Derive pivot from last interval set in table
    let rc = sp.ns.fetchEx.accTab.last
    if rc.isErr:
      break # no more => stop
    # Check last interval
    let blkRc = rc.value.data.avail.le(high(LeafItem))
    if blkRc.isErr:
      # Delete useless interval set, repeat
      sp.ns.fetchEx.accTab.del(rc.value.key)
      continue
    if blkRc.value.minPt < high(LeafItem) - accRangeMaxLen:
      # Start after somewhere in the middle of the last block
      start = blkRc.value.minPt + accRangeMaxLen
    else:
      # Otherwise start at 0
      discard
    break

  let accRange = AccTabEntryRef(
    pivot: start,
    avail: LeafRangeSet.init())

  trace "New accounts list for syncing", peer=sp, stateRoot=key, pivot=start

  # Statistics
  sp.ns.fetchEx.quCount.inc

  # Pre-filled with the largest possible interval
  discard accRange.avail.merge(low(LeafItem),high(LeafItem))

  # Append and curb LRU table as needed
  return sp.ns.fetchEx.accTab.lruAppend(key, accRange, sp.ns.buddiesMax)


proc fetchAccRange(atb: AccTabEntryRef): Result[LeafRange,void] =
  ## Fetch an interval from the account range list. Use the `atb.pivot` value
  ## as a start entry to fetch data from, wrapping around if necessary.
  block:
    # Check whether there the start point is in the middle of an interval
    let rc = atb.avail.le(atb.pivot)
    if rc.isOk:
      if atb.pivot <= rc.value.maxPt:
        let iv = LeafRange.new(atb.pivot, rc.value.maxPt)
        discard atb.avail.reduce(iv)
        return ok(iv)

  block:
    # Take the next interval to the right
    let rc = atb.avail.ge(atb.pivot)
    if rc.isOk:
      let iv = rc.value.withMaxLen
      discard atb.avail.reduce(iv)
      return ok(iv)

  # Otherwise wrap around
  let rc = atb.avail.ge()
  if rc.isOk:
    let iv = rc.value.withMaxLen
    discard atb.avail.reduce(iv)
    return ok(iv)

  err()


proc putAccRange(atb: AccTabEntryRef; iv: LeafRange) =
  discard atb.avail.merge(iv)

proc putAccRange(atb: AccTabEntryRef; a, b: LeafItem) =
  discard atb.avail.merge(a, b)


proc haveAccRange(atb: AccTabEntryRef): bool =
  0 < atb.avail.chunks


proc tickerStats(ns: Worker): TickerStats {.gcsafe.} =
  result.totalQueues = ns.fetchEx.quCount
  for it in ns.fetchEx.accTab.nextValues:
    if 0 < it.avail.chunks:
      result.avFillFactor += it.avail.freeFactor
      result.activeQueues.inc

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc fetchSetup*(ns: Worker) =
  ## Global set up
  ns.fetchBase = FetchEx()
  ns.fetchEx.accTab.init(ns.buddiesMax)
  ns.tickerSetup(cb = tickerStats)

proc fetchRelease*(ns: Worker) =
  ## Global clean up
  ns.tickerRelease()
  ns.fetchBase = nil

proc fetchStart*(sp: WorkerBuddy) =
  ## Initialise fetching for particular peer
  discard

proc fetchStop*(sp: WorkerBuddy) =
  ## Clean up for this peer
  discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetch*(peer: WorkerBuddy) {.async.} =

  trace "Fetching from peer", peer, ctrlState=peer.ctrl.state
  peer.tickerStartPeer()

  var
    stateRoot = peer.ctrl.stateRoot.get
    accTab = peer.getAccTab(stateRoot)

  while not peer.ctrl.stopped:

    if not accTab.haveAccRange():
      trace "Nothing more to sync from this peer", peer
      while not accTab.haveAccRange():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.

    if peer.ctrl.stateRoot.isNone:
      trace "No current state root for this peer", peer
      while not peer.ctrl.stopped and
            accTab.haveAccRange() and
            peer.ctrl.stateRoot.isNone:
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if stateRoot != peer.ctrl.stateRoot.get:
      stateRoot = peer.ctrl.stateRoot.get
      accTab = peer.getAccTab(stateRoot)
      peer.ctrl.stopped = false

    if peer.ctrl.stopRequest:
      trace "Pausing sync until we get a new state root", peer
      while not peer.ctrl.stopped and
            accTab.haveAccRange() and
            peer.ctrl.stateRoot.isSome and
            stateRoot == peer.ctrl.stateRoot.get:
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if peer.ctrl.stopped:
      continue

    # Get a new interval, a range of accounts to visit
    let iv = block:
      let rc = accTab.fetchAccRange()
      if rc.isErr:
        continue
      rc.value

    # Fetch data for this interval, function returned the range covered
    let rc = await peer.fetchAccounts(stateRoot, iv)
    if rc.isErr:
      accTab.putAccRange(iv) # fail => interval back to pool
    elif rc.value.maxPt < iv.maxPt:
      # return some unused range
      accTab.putAccRange(rc.value.maxPt + 1.u256, iv.maxPt)

  # while end

  trace "No more sync available from this peer", peer
  peer.tickerStopPeer()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

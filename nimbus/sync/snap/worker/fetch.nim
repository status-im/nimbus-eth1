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
  stew/[interval_set, keyed_queue],
  stint,
  ../../types,
  ../path_desc,
  ./fetch/[fetch_accounts, proof_db],
  "."/[ticker, worker_desc]

{.push raises: [Defect].}

type
  FetchEx = ref object of WorkerFetchBase
    accTab: AccLruCache      ## Global worker data
    quCount: uint64          ## Count visited roots
    lastPivot: NodeTag       ## Used for calculating pivots
    accRangeMaxLen: UInt256  ## Maximap interval length, high(u256)/#peers

  AccTabEntryRef = ref object
    ## Global worker table
    avail: LeafRangeSet      ## Accounts to visit (organised as ranges)
    pivot: NodeTag           ## Where to to start fetching from
    proof: ProofDbRef        ## Proof processing, TODO: find a better name
    base: WorkerFetchBase    ## Back reference (`FetchEx` not working, here)

  AccLruCache =
    KeyedQueue[TrieHash,AccTabEntryRef]

logScope:
  topics = "snap-fetch"

const
  accRangeMaxLen = ##\
    ## ask for that many accounts at once (not the range is sparse)
    (high(NodeTag) - low(NodeTag)) div 1000

  pivotAccIncrement = ##\
    ## increment when `lastPivot` would stay put
    10_000_000.u256

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `==`(a, b: AccTabEntryRef): bool =
  ## Just to make things clear, should be default action anyway
  cast[pointer](a) == cast[pointer](b)

proc fetchEx(ns: Worker): FetchEx =
  ## Getter
  ns.fetchBase.FetchEx

proc fetchEx(sp: WorkerBuddy): FetchEx =
  ## Getter
  sp.ns.fetchEx

proc withMaxLen(atb: AccTabEntryRef; iv: LeafRange): LeafRange =
  ## Reduce accounts interval to maximal size
  let maxlen = atb.base.FetchEx.accRangeMaxLen
  if 0 < iv.len and iv.len <= maxLen:
    iv
  else:
    LeafRange.new(iv.minPt, iv.minPt + maxLen - 1.u256)

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
  while true:
    # Derive pivot from last interval set in table
    let rc = sp.ns.fetchEx.accTab.last
    if rc.isErr:
      break # no more => stop
    # Check last interval
    let blkRc = rc.value.data.avail.le() # rightmost interval
    if blkRc.isErr:
      # Delete useless interval set, repeat
      sp.ns.fetchEx.accTab.del(rc.value.key)
      continue
    # use increasing `pivot` values
    if sp.ns.fetchEx.lastPivot < blkRc.value.minPt:
      sp.ns.fetchEx.lastPivot = blkRc.value.minPt
      break
    if sp.ns.fetchEx.lastPivot < high(NodeTag) - pivotAccIncrement:
      sp.ns.fetchEx.lastPivot = sp.ns.fetchEx.lastPivot + pivotAccIncrement
      break
    # Otherwise start at 0
    sp.ns.fetchEx.lastPivot = 0.to(NodeTag)
    break

  let accRange = AccTabEntryRef(
    pivot: sp.ns.fetchEx.lastPivot,
    avail: LeafRangeSet.init(),
    proof: ProofDBRef.init(key),
    base: sp.fetchEx)

  trace "New accounts list for syncing",
    peer=sp, stateRoot=key, pivot=sp.ns.fetchEx.lastPivot

  # Statistics
  sp.ns.fetchEx.quCount.inc

  # Pre-filled with the largest possible interval
  discard accRange.avail.merge(low(NodeTag),high(NodeTag))

  # Append and curb LRU table as needed
  return sp.ns.fetchEx.accTab.lruAppend(key, accRange, sp.ns.buddiesMax)


proc sameAccTab(sp: WorkerBuddy; key: TrieHash; accTab: AccTabEntryRef): bool =
  ## Verify that account list entry has not changed.
  let rc = sp.ns.fetchEx.accTab.eq(key)
  if rc.isErr:
    return accTab.isNil
  if not accTab.isNil:
    return accTab == rc.value


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
      let iv = atb.withMaxLen(rc.value)
      discard atb.avail.reduce(iv)
      return ok(iv)

  # Otherwise wrap around
  let rc = atb.avail.ge()
  if rc.isOk:
    let iv = atb.withMaxLen(rc.value)
    discard atb.avail.reduce(iv)
    return ok(iv)

  err()


proc putAccRange(atb: AccTabEntryRef; iv: LeafRange) =
  discard atb.avail.merge(iv)

proc putAccRange(atb: AccTabEntryRef; a, b: NodeTag) =
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
  ns.fetchEx.accRangeMaxLen = high(UInt256) div ns.buddiesMax.u256
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

proc fetch*(sp: WorkerBuddy) {.async.} =
  ## Concurrently fetch account data. The data are fetched from `sp.peer` where
  ## `sp` is the argument descriptor. Currently, accounts data are fetched but
  ## not further processed (i.e. discarded.)
  ##
  ## The accounts requested depend on
  ## * the currrent state root `sp.ctrl.stateRoot`,
  ## * an account list `accTab(stateRoot)` depending on the current state root.
  ##
  ## The account list keeps track of account ranges already requested. It is
  ## shared among  all instances of `fetch()` (sharing the same `ds`
  ## descriptor.) So the accounts requested for a shared accounts list are
  ## mutually exclusive.
  ##
  ## Currently the accounts list to retrieve by `accTab()` is implemented as
  ## follows.
  ## * For each state root there is a separate accounts list.
  ## * If the state root changes and there is no account list yet, create a
  ##   new one.
  ## * Account ranges are fetched from an accoiunts list with increasing values
  ##   starting at a (typically positive) `pivot` value. The fetch wraps around
  ##   when the highest values are exhausted. This `pivot` value is increased
  ##   with each new accounts list (derived from the last used accounts list.)
  ## * Accounts list are kept in a LRU table and automatically cleared. The
  ##   size of the  LRU table is set to `sp.ns.buddiesMax`, the maximal number
  ##   of workers or peers.

  trace "Fetching from peer", peer=sp, ctrlState=sp.ctrl.state
  sp.tickerStartPeer()

  while not sp.ctrl.stopped:

    # We need a state root and an access range list (depending on state root)
    if sp.ctrl.stateRoot.isNone:
      trace "Currently no state root", peer=sp
      # Wait for a new state root
      while not sp.ctrl.stopped and
            sp.ctrl.stateRoot.isNone:
        await sleepAsync(5.seconds)
      continue

    # Ok, here is the `stateRoot`, tentatively try the access range list
    let
      stateRoot = sp.ctrl.stateRoot.get
      accTab = sp.getAccTab(stateRoot)

    if not accTab.haveAccRange():
      trace "Currently no account ranges", peer=sp
      # Account ranges exhausted, wait for a new state root
      while not sp.ctrl.stopped and
            sp.ctrl.stateRoot.isSome and
            stateRoot == sp.ctrl.stateRoot.get and
            sp.sameAccTab(stateRoot, accTab) and
            not accTab.haveAccRange():
        await sleepAsync(5.seconds)
      continue

    # Get a range of accounts to fetch from
    let iv = block:
      let rc = accTab.fetchAccRange()
      if rc.isErr:
        continue
      rc.value

    # Fetch data for this range delegated to `fetchAccounts()`
    let dd = block:
      let rc = await sp.fetchAccounts(stateRoot, iv)
      if rc.isErr:
        accTab.putAccRange(iv) # fail => interval back to pool
        case rc.error:
        of NetworkProblem, MissingProof, AccountsMinTooSmall,
           AccountsMaxTooLarge:
          # Mark this peer dead, i.e. avoid fetching from this peer for a while
          sp.stats.major.networkErrors.inc()
          sp.ctrl.zombie = true
        of NothingSerious:
          discard
        of NoAccountsForStateRoot:
          # One could wait for a new state root but this may result in a
          # temporary standstill if all `fetch()` instances do the same. So
          # waiting for a while here might be preferable in the hope that the
          # situation changes at the peer.
          await sleepAsync(5.seconds)
        continue
      rc.value

    # Register consumed accounts range
    if dd.consumed < iv.len:
      # return some unused range
      accTab.putAccRange(iv.minPt + dd.consumed.u256, iv.maxPt)

    # Statistics
    sp.tickerCountAccounts(0, dd.data.accounts.len)

    # Process data
    block:
      let rc = accTab.proof.mergeProved(
        iv.minPt, dd.data.accounts, dd.data.proof)
      if rc.isErr:
        discard # ??

  # while end

  trace "Done syncing for this peer", peer=sp, ctrlState=sp.ctrl.state
  sp.tickerStopPeer()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

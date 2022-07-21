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
  std/[hashes, math],
  chronos,
  eth/[common/eth_types, p2p],
  nimcrypto/keccak,
  stew/[interval_set, keyed_queue],
  stint,
  "../.."/[sync_desc, types],
  ".."/[path_desc, worker_desc],
  ./fetch/[fetch_accounts, proof_db],
  ./ticker

{.push raises: [Defect].}

type
  FetchEx = ref object of WorkerFetchBase
    accTab: AccLruCache      ## Global worker data
    quCount: uint64          ## Count visited roots
    lastPivot: NodeTag       ## Used for calculating pivots
    accRangeMaxLen: UInt256  ## Maximap interval length, high(u256)/#peers
    pdb: ProofDb             ## Proof processing

  AccTabEntryRef = ref object
    ## Global worker table
    avail: LeafRangeSet      ## Accounts to visit (organised as ranges)
    pivot: NodeTag           ## Where to to start fetching from
    base: WorkerFetchBase    ## Back reference (`FetchEx` not working, here)

  AccLruCache =
    KeyedQueue[Hash256,AccTabEntryRef]

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

proc hash(h: Hash256): Hash =
  ## Mixin for `Table` or `keyedQueue`
  h.data.hash

proc `==`(a, b: AccTabEntryRef): bool =
  ## Just to make things clear, should be default action anyway
  cast[pointer](a) == cast[pointer](b)

proc fetchEx(ctx: SnapCtxRef): FetchEx =
  ## Getter
  ctx.data.fetchBase.FetchEx

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

proc getAccTab(buddy: SnapBuddyRef; key: Hash256): AccTabEntryRef =
  ## Fetch LRU table item, create a new one if missing.
  let
    ctx = buddy.ctx
    peer = buddy.peer
  
  # fetch existing table (if any)
  block:
    let rc = ctx.fetchEx.accTab.lruFetch(key)
    if rc.isOk:
      # Item was moved to the end of queue
      return rc.value

  # Calculate some new start address for the range fetcher
  while true:
    # Derive pivot from last interval set in table
    let rc = ctx.fetchEx.accTab.last
    if rc.isErr:
      break # no more => stop
    # Check last interval
    let blkRc = rc.value.data.avail.le() # rightmost interval
    if blkRc.isErr:
      # Delete useless interval set, repeat
      ctx.fetchEx.accTab.del(rc.value.key)
      continue
    # use increasing `pivot` values
    if ctx.fetchEx.lastPivot < blkRc.value.minPt:
      ctx.fetchEx.lastPivot = blkRc.value.minPt
      break
    if ctx.fetchEx.lastPivot < high(NodeTag) - pivotAccIncrement:
      ctx.fetchEx.lastPivot = ctx.fetchEx.lastPivot + pivotAccIncrement
      break
    # Otherwise start at 0
    ctx.fetchEx.lastPivot = 0.to(NodeTag)
    break

  let accRange = AccTabEntryRef(
    pivot: ctx.fetchEx.lastPivot,
    avail: LeafRangeSet.init(),
    base: ctx.fetchEx)

  trace "New accounts list for syncing",
    peer, stateRoot=key, pivot=ctx.fetchEx.lastPivot

  # Statistics
  ctx.fetchEx.quCount.inc

  # Pre-filled with the largest possible interval
  discard accRange.avail.merge(low(NodeTag),high(NodeTag))

  # Append and curb LRU table as needed
  return ctx.fetchEx.accTab.lruAppend(key, accRange, ctx.buddiesMax)


proc sameAccTab(
    buddy: SnapBuddyRef;
    key: Hash256;
    accTab: AccTabEntryRef
     ): bool =
  ## Verify that account list entry has not changed.
  let
    ctx = buddy.ctx
    rc = ctx.fetchEx.accTab.eq(key)
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


proc meanStdDev(sum, sqSum: float; length: int): (float,float) =
  if 0 < length:
    result[0] = sum / length.float
    result[1] = sqrt(sqSum / length.float - result[0] * result[0])

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc fetchSetup*(ctx: SnapCtxRef) =
  ## Global set up
  ctx.data.fetchBase = FetchEx()
  ctx.fetchEx.accTab.init(ctx.buddiesMax)
  ctx.fetchEx.accRangeMaxLen = high(UInt256) div ctx.buddiesMax.u256
  ctx.fetchEx.pdb.init(ctx.chain.getTrieDB)

proc fetchRelease*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.data.fetchBase = nil

proc fetchStart*(buddy: SnapBuddyRef) =
  ## Initialise fetching for particular peer
  let ctx = buddy.ctx

proc fetchStop*(buddy: SnapBuddyRef) =
  ## Clean up for this peer
  let ctx = buddy.ctx

proc tickerUpdate*(ctx: SnapCtxRef): TickerStatsUpdater =
  result = proc: TickerStats =
    var
      aSum, aSqSum, uSum, uSqSum: float
      count = 0
    for kvp in ctx.fetchEx.accTab.nextPairs:

      # Accounts mean & variance
      let aLen = ctx.fetchEx.pdb.nAccounts(kvp.key.TrieHash).float
      if 0 < aLen:
        count.inc
        aSum += aLen
        aSqSum += aLen * aLen

        # Fill utilisation mean & variance
        let fill = kvp.data.avail.freeFactor
        uSum += fill
        uSqSum += fill * fill

    let
      tabLen = ctx.fetchEx.accTab.len
      pivotBlock =
        if ctx.data.stateHeader.isSome:
          some(ctx.data.stateHeader.get.blockNumber)
        else: none(BlockNumber)
    TickerStats(
      pivotBlock:    pivotBlock,
      activeQueues:  tabLen,
      flushedQueues: ctx.fetchEx.quCount.int64 - tabLen,
      accounts:      meanStdDev(aSum, aSqSum, count),
      fillFactor:    meanStdDev(uSum, uSqSum, count))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchExec*(buddy: SnapBuddyRef) {.async.} =
  ## Concurrently fetch account data. The data are fetched from `buddy.peer`
  ## where `buddy` is the argument descriptor. Currently, accounts data are
  ## fetched but not further processed (i.e. discarded.)
  ##
  ## The accounts requested depend on
  ## * the currrent state root `buddy.data.stateRoot`,
  ## * an account list `accTab(stateRoot)` depending on the current state root.
  ##
  ## The account list keeps track of account ranges already requested. It is
  ## shared among  all instances of `fetch()` (sharing the same `buddy`
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
  ##   size of the  LRU table is set to `buddy.ctx.buddiesMax`, the maximal
  ##   number of workers or peers.
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # We need a state root and an access range list (depending on state root)
  if ctx.data.stateHeader.isNone:
    trace "Currently no state root", peer
    return

  # Ok, here is the `stateRoot`, tentatively try the access range list
  let
    stateRoot = ctx.data.stateHeader.unsafeGet.stateRoot
    accTab = buddy.getAccTab(stateRoot)

  if not accTab.haveAccRange():
    trace "Currently no account ranges", peer
    return

  # Get a range of accounts to fetch from
  let iv = block:
    let rc = accTab.fetchAccRange()
    if rc.isErr:
      return
    rc.value

  # Fetch data for this range delegated to `fetchAccounts()`
  let dd = block:
    let rc = await buddy.fetchAccounts(stateRoot.TrieHash, iv)
    if rc.isErr:
      accTab.putAccRange(iv) # fail => interval back to pool
      case rc.error:
      of NetworkProblem, MissingProof, AccountsMinTooSmall,
         AccountsMaxTooLarge:
        # Mark this peer dead, i.e. avoid fetching from this peer for a while
        buddy.data.stats.major.networkErrors.inc()
        buddy.ctrl.zombie = true
      of NothingSerious:
        discard
      of NoAccountsForStateRoot:
        # One could wait for a new state root but this may result in a
        # temporary standstill if all `fetch()` instances do the same. So
        # waiting for a while here might be preferable in the hope that the
        # situation changes at the peer.
        await sleepAsync(5.seconds)
      return
    rc.value

  # Register consumed accounts range
  if dd.consumed < iv.len:
    # return some unused range
    accTab.putAccRange(iv.minPt + dd.consumed.u256, iv.maxPt)

  # Process data
  block:
    let rc = ctx.fetchEx.pdb.mergeProved(
      buddy.peer, stateRoot.TrieHash, iv.minPt, dd.data)
    if rc.isErr:
      discard # ??

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

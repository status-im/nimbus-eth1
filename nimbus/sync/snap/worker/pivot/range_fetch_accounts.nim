# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch account ranges
## ====================
##
## Acccount ranges not on the database yet are organised in the set
## `env.fetchAccounts.unprocessed` of intervals (of account hashes.)
##
## When processing, the following happens.
##
## * Some interval `iv` is removed from the `env.fetchAccounts.unprocessed`
##   set. This interval set might then be safely accessed and manipulated by
##   other worker instances.
##
## * The data points in the interval `iv` (aka ccount hashes) are fetched from
##   another peer over the network.
##
## * The received data points of the interval `iv` are verified and merged
##   into the persistent database.
##
## * Data points in `iv` that were invalid or not recevied from the network
##   are merged back it the set `env.fetchAccounts.unprocessed`. The remainder
##   of successfully added ranges are added to `env.fetchAccounts.processed`.
##
import
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  stint,
  ../../../../utils/prettify,
  ../../../sync_desc,
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_account_range],
  ../db/[hexary_envelope, snapdb_accounts],
  ./swap_in

{.push raises: [Defect].}

logScope:
  topics = "snap-range"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Accounts range " & info

proc `$`(rs: NodeTagRangeSet): string =
  rs.fullFactor.toPC(0)

proc `$`(iv: NodeTagRange): string =
  iv.fullFactor.toPC(3)

proc fetchCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string =
  let
    ctx = buddy.ctx
    nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "runState=" & $buddy.ctrl.state & "," &
    "nStoQu=" & $nStoQu & "," &
    "nSlotLists=" & $env.nSlotLists & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getUnprocessed(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): Result[NodeTagRange,void] =
  ## Fetch an interval from one of the account range lists.
  let accountRangeMax = high(UInt256) div buddy.ctx.buddiesMax.u256

  env.fetchAccounts.unprocessed.fetch accountRangeMax

# ------------------------------------------------------------------------------
#  Private functions: do the account fetching for one round
# ------------------------------------------------------------------------------

proc accountsRangefetchImpl(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): Future[bool]
      {.async.} =
  ## Fetch accounts and store them in the database. Returns true while more
  ## data can probably be fetched.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    db = ctx.data.snapDb
    fa = env.fetchAccounts
    stateRoot = env.stateHeader.stateRoot

  # Get a range of accounts to fetch from
  let iv = block:
    let rc = buddy.getUnprocessed(env)
    if rc.isErr:
      when extraTraceMessages:
        trace logTxt "currently all processed", peer, ctx=buddy.fetchCtx(env)
      return
    rc.value

  # Process received accounts and stash storage slots to fetch later
  let dd = block:
    let
      pivot = "#" & $env.stateHeader.blockNumber
      rc = await buddy.getAccountRange(stateRoot, iv, pivot)
    if rc.isErr:
      fa.unprocessed.merge iv # fail => interval back to pool
      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        when extraTraceMessages:
          trace logTxt "fetch error", peer, ctx=buddy.fetchCtx(env),
            reqLen=iv.len, error
      return
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.data.errors.resetComError()

  let
    gotAccounts = dd.data.accounts.len # comprises `gotStorage`
    gotStorage = dd.withStorage.len

  # Now, we fully own the scheduler. The original interval will savely be placed
  # back for a moment (the `unprocessed` range set to be corrected below.)
  fa.unprocessed.merge iv

  # Processed accounts hashes are set up as a set of intervals which is needed
  # if the data range returned from the network contains holes.
  let covered = NodeTagRangeSet.init()
  if 0 < dd.data.accounts.len:
    discard covered.merge(iv.minPt, dd.data.accounts[^1].accKey.to(NodeTag))
  else:
    discard covered.merge iv

  let gaps = block:
    # No left boundary check needed. If there is a gap, the partial path for
    # that gap is returned by the import function to be registered, below.
    let rc = db.importAccounts(
      peer, stateRoot, iv.minPt, dd.data, noBaseBoundCheck = true)
    if rc.isErr:
      # Bad data, just try another peer
      buddy.ctrl.zombie = true
      when extraTraceMessages:
        trace logTxt "import failed", peer, ctx=buddy.fetchCtx(env),
          gotAccounts, gotStorage, reqLen=iv.len, covered, error=rc.error
      return
    rc.value

  # Statistics
  env.nAccounts.inc(gotAccounts)

  # Punch holes into the reported range of received accounts from the network
  # if it there are gaps (described by dangling nodes.)
  for w in gaps.innerGaps:
    discard covered.reduce w.partialPath.hexaryEnvelope

  # Update book keeping
  for w in covered.increasing:
    # Remove the processed range from the batch of unprocessed ones.
    fa.unprocessed.reduce w
    # Register consumed intervals on the accumulators over all state roots.
    discard buddy.ctx.data.coveredAccounts.merge w
    discard fa.processed.merge w

  # Register accounts with storage slots on the storage TODO list.
  env.fetchStorageFull.merge dd.withStorage

  # Swap in from other pivots unless mothballed, already
  var nSwapInLaps = 0
  if not env.archived:
    when extraTraceMessages:
      trace logTxt "before swap in", peer, ctx=buddy.fetchCtx(env), covered,
        gotAccounts, gotStorage, processed=fa.processed,
        nProcessedChunks=fa.processed.chunks.uint.toSI

    nSwapInLaps = ctx.swapInAccounts env

  when extraTraceMessages:
    trace logTxt "request done", peer, ctx=buddy.fetchCtx(env), gotAccounts,
      gotStorage, nSwapInLaps, covered, processed=fa.processed,
      nProcessedChunks=fa.processed.chunks.uint.toSI

  return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rangeFetchAccounts*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetch accounts and store them in the database.
  let
    fa = env.fetchAccounts

  if not fa.processed.isFull():
    let
      ctx = buddy.ctx
      peer = buddy.peer

    when extraTraceMessages:
      trace logTxt "start", peer, ctx=buddy.fetchCtx(env)

    var nFetchAccounts = 0                     # for logging
    while not fa.processed.isFull() and
          buddy.ctrl.running and
          not env.archived:
      nFetchAccounts.inc
      if not await buddy.accountsRangefetchImpl(env):
        break

      # Clean up storage slots queue first it it becomes too large
      let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
      if snapStorageSlotsQuPrioThresh < nStoQu:
        break

    when extraTraceMessages:
      trace logTxt "done", peer, ctx=buddy.fetchCtx(env), nFetchAccounts

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
## When processing, the followin happens.
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
##   are merged back it the set `env.fetchAccounts.unprocessed`.
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
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  # Get a range of accounts to fetch from
  let iv = block:
    let rc = buddy.getUnprocessed(env)
    if rc.isErr:
      when extraTraceMessages:
        trace logTxt "currently all processed", peer, pivot
      return
    rc.value

  # Process received accounts and stash storage slots to fetch later
  let dd = block:
    let rc = await buddy.getAccountRange(stateRoot, iv, pivot)
    if rc.isErr:
      fa.unprocessed.merge iv # fail => interval back to pool
      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        when extraTraceMessages:
          trace logTxt "fetch error => stop", peer, pivot, reqLen=iv.len, error
      return
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.data.errors.resetComError()

  let
    gotAccounts = dd.data.accounts.len # comprises `gotStorage`
    gotStorage = dd.withStorage.len

  #when extraTraceMessages:
  #  trace logTxt "fetched", peer, gotAccounts, gotStorage,
  #    pivot, reqLen=iv.len, gotLen=dd.consumed.len

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
        trace logTxt "import failed => stop", peer, gotAccounts, gotStorage,
          pivot, reqLen=iv.len, gotLen=covered.total, error=rc.error
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

  var nSwapInLaps = 0
  if not env.archived and
     swapInAccountsCoverageTrigger <= ctx.pivotAccountsCoverage():
    # Swap in from other pivots
    when extraTraceMessages:
      trace logTxt "before swap in", peer, pivot, gotAccounts, gotStorage,
        coveredHere=covered.fullFactor.toPC(2),
        processed=fa.processed.fullFactor.toPC(2),
        nProcessedChunks=fa.processed.chunks.uint.toSI

    if swapInAccountsPivotsMin <= ctx.data.pivotTable.len:
      nSwapInLaps = buddy.swapInAccounts(env)

  when extraTraceMessages:
    trace logTxt "request done", peer, pivot, gotAccounts, gotStorage,
      nSwapInLaps, coveredHere=covered.fullFactor.toPC(2),
      processed=fa.processed.fullFactor.toPC(2),
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
      pivot = "#" & $env.stateHeader.blockNumber # for logging

    when extraTraceMessages:
      trace logTxt "start", peer, pivot,
        nNodesCheck=fa.nodes.check.len, nNodesMissing=fa.nodes.missing.len

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
      trace logTxt "done", peer, pivot, nFetchAccounts,
        nNodesCheck=fa.nodes.check.len, nNodesMissing=fa.nodes.missing.len,
        runState=buddy.ctrl.state

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

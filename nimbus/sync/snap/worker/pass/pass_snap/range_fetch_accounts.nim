# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch accounts DB ranges
## ========================
##
## Acccount ranges allocated on the database are organised in the set
## `env.fetchAccounts.processed` and the ranges that can be fetched are in
## the pair of range sets `env.fetchAccounts.unprocessed`. The ranges of these
## sets are mutually disjunct yet the union of all ranges does not fully
## comprise the complete `[0,2^256]` range. The missing parts are the ranges
## currently processed by worker peers.
##
## Algorithm
## ---------
##
## * Some interval `iv` is removed from the `env.fetchAccounts.unprocessed`
##   pair of set (so the interval `iv` is protected from other worker
##   instances and might be safely accessed and manipulated by this function.)
##   Stop if there are no more intervals.
##
## * The accounts data points in the interval `iv` (aka account hashes) are
##   fetched from the network. This results in *key-value* pairs for accounts.
##
## * The received *key-value* pairs from the previous step are verified and
##   merged into the accounts hexary trie persistent database.
##
## * *Key-value* pairs that were invalid or were not recevied from the network
##   are merged back into the range set `env.fetchAccounts.unprocessed`. The
##   remainder of successfully added ranges (and verified key gaps) are merged
##   into `env.fetchAccounts.processed`.
##
## * For *Key-value* pairs that have an active account storage slot sub-trie,
##   the account including administrative data is queued in
##   `env.fetchStorageFull`.
##
{.push raises: [].}

import
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  "../../../.."/[sync_desc, types],
  "../../.."/[constants, range_desc, worker_desc],
  ../../com/[com_error, get_account_range],
  ../../db/[hexary_envelope, snapdb_accounts],
  ./helper/[storage_queue, swap_in]

logScope:
  topics = "snap-acc"

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Accounts fetch " & info

proc `$`(rs: NodeTagRangeSet): string =
  rs.fullPC3

proc `$`(iv: NodeTagRange): string =
  iv.fullPC3

proc fetchCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string {.used.} =
  "{" &
    "piv=" & env.stateHeader.blockNumber.toStr & "," &
    "ctl=" & $buddy.ctrl.state & "," &
    "nStoQ=" & $env.storageQueueTotal() & "," &
    "nSlotLists=" & $env.nSlotLists & "," &
    "nConQ=" & $env.fetchContracts.len & "," &
    "nCon=" & $env.nContracts & "}"

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
    db = ctx.pool.snapDb
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
      pivot = env.stateHeader.blockNumber.toStr
      rc = await buddy.getAccountRange(stateRoot, iv, pivot)
    if rc.isErr:
      fa.unprocessed.mergeSplit iv # fail => interval back to pool
      if await buddy.ctrl.stopAfterSeriousComError(rc.error, buddy.only.errors):
        when extraTraceMessages:
          trace logTxt "fetch error", peer, ctx=buddy.fetchCtx(env),
            reqLen=iv, error=rc.error
        discard
      return
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.only.errors.resetComError()

  let
    gotAccounts = dd.data.accounts.len # comprises `gotStorage`
    gotStorage {.used.} = dd.withStorage.len

  # Now, we fully own the scheduler. The original interval will savely be placed
  # back for a moment (the `unprocessed` range set to be corrected below.)
  fa.unprocessed.mergeSplit iv

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
    let rc = db.importAccounts(peer, stateRoot, iv.minPt, dd.data)
    if rc.isErr:
      # Bad data, just try another peer
      buddy.ctrl.zombie = true
      # Failed to store on database, not much that can be done here
      error logTxt "import failed", peer, ctx=buddy.fetchCtx(env),
        gotAccounts, gotStorage, reqLen=iv, covered, error=rc.error
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
    discard fa.processed.merge w
    discard ctx.pool.coveredAccounts.merge w
    ctx.pivotAccountsCoverage100PcRollOver() # update coverage level roll over

  # Register accounts with storage slots on the storage TODO list.
  env.storageQueueAppend dd.withStorage

  # Register accounts with contracts to fetch on the TODO list
  for w in dd.withContract:
    env.fetchContracts[w.codeHash] = w.accKey

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
      nProcessedChunks=fa.processed.chunks.uint.toSI,
      nContracts=dd.withContract.len

  return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rangeFetchAccounts*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetch accounts and store them in the database.
  trace logTxt "start", peer=buddy.peer, ctx=buddy.fetchCtx(env)

  let fa = env.fetchAccounts
  var nFetchAccounts = 0                     # for logging
  if not fa.processed.isFull():

    while not fa.processed.isFull() and
          buddy.ctrl.running and
          not env.archived:
      # May repeat fetching with re-arranged request intervals
      if not await buddy.accountsRangefetchImpl(env):
        break

      nFetchAccounts.inc

      # Clean up storage slots or contracts queues now if they become too large
      if storageSlotsQuPrioThresh < env.storageQueueAvail() or
         contractsQuPrioThresh < env.fetchContracts.len:
        break

      when extraTraceMessages:
        trace logTxt "looping", peer=buddy.peer, ctx=buddy.fetchCtx(env),
          nFetchAccounts, isFull=fa.processed.isFull()

  trace logTxt "done", peer=buddy.peer, ctx=buddy.fetchCtx(env), nFetchAccounts

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[com_error, get_account_range],
  ./db/snapdb_accounts

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

proc withMaxLen(
    buddy: SnapBuddyRef;
    iv: NodeTagRange;
    maxlen: UInt256;
      ): NodeTagRange =
  ## Reduce accounts interval to maximal size
  if 0 < iv.len and iv.len <= maxLen:
    iv
  else:
    NodeTagRange.new(iv.minPt, iv.minPt + (maxLen - 1.u256))

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getUnprocessed(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): Result[NodeTagRange,void] =
  ## Fetch an interval from one of the account range lists.
  let accountRangeMax = high(UInt256) div buddy.ctx.buddiesMax.u256

  ## Swap batch queues if the first is empty
  if 0 == env.fetchAccounts.unprocessed[0].chunks and
     0 < env.fetchAccounts.unprocessed[1].chunks:
    swap(env.fetchAccounts.unprocessed[0], env.fetchAccounts.unprocessed[1])

  for ivSet in env.fetchAccounts.unprocessed:
    let rc = ivSet.ge()
    if rc.isOk:
      let iv = buddy.withMaxLen(rc.value, accountRangeMax)
      discard ivSet.reduce(iv)
      return ok(iv)

  err()

proc putUnprocessed(
    buddy: SnapBuddyRef;
    iv: NodeTagRange;
    env: SnapPivotRef;
      ) =
  ## Shortcut
  discard env.fetchAccounts.unprocessed[1].merge(iv)

proc delUnprocessed(
    buddy: SnapBuddyRef;
    iv: NodeTagRange;
    env: SnapPivotRef;
       ) =
  ## Shortcut
  for ivSet in env.fetchAccounts.unprocessed:
    discard ivSet.reduce(iv)

proc markGloballyProcessed(buddy: SnapBuddyRef; iv: NodeTagRange) =
  ## Shortcut
  discard buddy.ctx.data.coveredAccounts.merge(iv)

# ------------------------------------------------------------------------------
#  Private functions: do the account fetching for one round
# ------------------------------------------------------------------------------

proc accountsRangefetchImpl(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): Future[bool] {.async.} =
  ## Fetch accounts and store them in the database. Returns true while more
  ## data can probably be fetched.
  let
    ctx = buddy.ctx
    peer = buddy.peer
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
      buddy.putUnprocessed(iv, env) # fail => interval back to pool
      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        when extraTraceMessages:
          trace logTxt "fetch error => stop", peer, pivot, reqLen=iv.len, error
      return
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.data.errors.resetComError()

  let
    gotAccounts = dd.data.accounts.len
    gotStorage = dd.withStorage.len

  #when extraTraceMessages:
  #  trace logTxt "fetched", peer, gotAccounts, gotStorage,
  #    pivot, reqLen=iv.len, gotLen=dd.consumed.len

  block:
    let rc = ctx.data.snapDb.importAccounts(peer, stateRoot, iv.minPt, dd.data)
    if rc.isErr:
      # Bad data, just try another peer
      buddy.putUnprocessed(iv, env)
      buddy.ctrl.zombie = true
      when extraTraceMessages:
        trace logTxt "import failed => stop", peer, gotAccounts, gotStorage,
          pivot, reqLen=iv.len, gotLen=dd.consumed.len, error=rc.error
      return

  # Statistics
  env.nAccounts.inc(gotAccounts)

  # Register consumed intervals on the accumulator over all state roots
  buddy.markGloballyProcessed(dd.consumed)

  # Register consumed/bulk-imported accounts range
  block:
    doAssert dd.consumed.minPt == iv.minPt
    # Try case where `dd.consumed` < `iv`, restore some unprocessed range
    let rc = iv - dd.consumed
    if rc.isOk:
      buddy.putUnprocessed(rc.value, env)
    else:
      # Otherwise `dd.consumed` might exceed `iv`
      buddy.delUnprocessed(dd.consumed, env)

  # Store accounts on the storage TODO list.
  env.fetchStorage.merge dd.withStorage

  return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rangeFetchAccounts*(buddy: SnapBuddyRef) {.async.} =
  ## Fetch accounts and store them in the database.
  let env = buddy.data.pivotEnv
  if not env.fetchAccounts.unprocessed.isEmpty():
    let
      ctx = buddy.ctx
      peer = buddy.peer
      pivot = "#" & $env.stateHeader.blockNumber # for logging

    when extraTraceMessages:
      trace logTxt "start", peer, pivot

    var nFetchAccounts = 0
    while not env.fetchAccounts.unprocessed.isEmpty() and
          buddy.ctrl.running and
          env == buddy.data.pivotEnv:
      nFetchAccounts.inc
      if not await buddy.accountsRangefetchImpl(env):
        break

    when extraTraceMessages:
      trace logTxt "done", peer, pivot, nFetchAccounts,
        runState=buddy.ctrl.state

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

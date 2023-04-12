# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles,
  chronos,
  eth/p2p,
  stew/[interval_set, keyed_queue],
  ../../../sync_desc,
  ".."/[pivot, ticker],
  ../pivot/storage_queue_helper,
  ../db/[hexary_desc, snapdb_pivot],
  "../.."/[range_desc, update_beacon_header, worker_desc],
  play_desc

logScope:
  topics = "snap-play"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc recoveryStepContinue(ctx: SnapCtxRef): Future[bool] {.async.} =
  let recov = ctx.pool.recovery
  if recov.isNil:
    return false

  let
    checkpoint =
      "#" & $recov.state.header.blockNumber & "(" & $recov.level & ")"
    topLevel = recov.level == 0
    env = block:
      let rc = ctx.pool.pivotTable.eq recov.state.header.stateRoot
      if rc.isErr:
        error "Recovery pivot context gone", checkpoint, topLevel
        return false
      rc.value

  # Cosmetics: allow other processes (e.g. ticker) to log the current recovery
  # state. There is no other intended purpose of this wait state.
  await sleepAsync 1100.milliseconds

  #when extraTraceMessages:
  #  trace "Recovery continued ...", checkpoint, topLevel,
  #    nAccounts=recov.state.nAccounts, nDangling=recov.state.dangling.len

  # Update pivot data from recovery checkpoint
  env.pivotRecoverFromCheckpoint(ctx, topLevel)

  # Fetch next recovery record if there is any
  if recov.state.predecessor.isZero:
    #when extraTraceMessages:
    #  trace "Recovery done", checkpoint, topLevel
    return false
  let rc = ctx.pool.snapDb.pivotRecoverDB(recov.state.predecessor)
  if rc.isErr:
    when extraTraceMessages:
      trace "Recovery stopped at pivot stale checkpoint", checkpoint, topLevel
    return false

  # Set up next level pivot checkpoint
  ctx.pool.recovery = SnapRecoveryRef(
    state: rc.value,
    level: recov.level + 1)

  # Push onto pivot table and continue recovery (i.e. do not stop it yet)
  ctx.pool.pivotTable.reverseUpdate(ctx.pool.recovery.state.header, ctx)

  return true # continue recovery

# ------------------------------------------------------------------------------
# Private functions, snap sync handlers
# ------------------------------------------------------------------------------

proc snapSyncPool(buddy: SnapBuddyRef, last: bool; lap: int): bool =
  ## Enabled when `buddy.ctrl.poolMode` is `true`
  ##
  let ctx = buddy.ctx
  result = true

  # Clean up empty pivot slots (never the top one)
  var rc = ctx.pool.pivotTable.beforeLast
  while rc.isOK:
    let (key, env) = (rc.value.key, rc.value.data)
    if env.fetchAccounts.processed.isEmpty:
      ctx.pool.pivotTable.del key
    rc = ctx.pool.pivotTable.prev(key)


proc snapSyncDaemon(ctx: SnapCtxRef) {.async.} =
  ## Enabled while `ctx.daemon` is `true`
  ##
  if not ctx.pool.recovery.isNil:
    if not await ctx.recoveryStepContinue():
      # Done, stop recovery
      ctx.pool.recovery = nil
      ctx.daemon = false

      # Update logging
      if not ctx.pool.ticker.isNil:
        ctx.pool.ticker.stopRecovery()


proc snapSyncSingle(buddy: SnapBuddyRef) {.async.} =
  ## Enabled while
  ## * `buddy.ctrl.multiOk` is `false`
  ## * `buddy.ctrl.poolMode` is `false`
  ##
  let ctx = buddy.ctx

  # External beacon header updater
  await buddy.updateBeaconHeaderFromFile()

  await buddy.pivotApprovePeer()
  buddy.ctrl.multiOk = true


proc snapSyncMulti(buddy: SnapBuddyRef): Future[void] {.async.} =
  ## Enabled while
  ## * `buddy.ctx.multiOk` is `true`
  ## * `buddy.ctx.poolMode` is `false`
  ##
  let
    ctx = buddy.ctx

    # Fetch latest state root environment
    env = block:
      let rc = ctx.pool.pivotTable.lastValue
      if rc.isErr:
        buddy.ctrl.multiOk = false
        return # nothing to do
      rc.value

    peer = buddy.peer
    pivot = "#" & $env.stateHeader.blockNumber # for logging
    fa = env.fetchAccounts

  # Check whether this pivot is fully downloaded
  if env.fetchAccounts.processed.isFull and env.storageQueueTotal() == 0:
    # Switch to full sync => final state
    ctx.playMode = PreFullSyncMode
    trace "Switch to full sync", peer, pivot, nAccounts=env.nAccounts,
      processed=fa.processed.fullPC3, nStoQu=env.storageQueueTotal(),
      nSlotLists=env.nSlotLists
    return

  # If this is a new snap sync pivot, the previous one can be cleaned up and
  # archived. There is no point in keeping some older space consuming state
  # data any longer.
  ctx.pool.pivotTable.beforeTopMostlyClean()

  when extraTraceMessages:
    trace "Multi sync runner", peer, pivot, nAccounts=env.nAccounts,
      processed=fa.processed.fullPC3, nStoQu=env.storageQueueTotal(),
      nSlotLists=env.nSlotLists

  # This one is the syncing work horse which downloads the database
  await env.execSnapSyncAction(buddy)

  # Various logging entries (after accounts and storage slots download)
  let
    nAccounts = env.nAccounts
    nSlotLists = env.nSlotLists
    processed = fa.processed.fullPC3

  # Archive this pivot eveironment if it has become stale
  if env.archived:
    when extraTraceMessages:
      trace "Mothballing", peer, pivot, nAccounts, nSlotLists
    env.pivotMothball()
    return

  # Save state so sync can be resumed at next start up
  let rc = env.saveCheckpoint(ctx)
  if rc.isOk:
    when extraTraceMessages:
      trace "Saved recovery checkpoint", peer, pivot, nAccounts, processed,
        nStoQu=env.storageQueueTotal(),  nSlotLists, blobSize=rc.value
    return

  error "Failed to save recovery checkpoint", peer, pivot, nAccounts,
    processed, nStoQu=env.storageQueueTotal(), nSlotLists, error=rc.error

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc playSnapSyncSpecs*: PlaySyncSpecs =
  ## Return snap sync handler environment
  PlaySyncSpecs(
    pool:   snapSyncPool,
    daemon: snapSyncDaemon,
    single: snapSyncSingle,
    multi:  snapSyncMulti)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

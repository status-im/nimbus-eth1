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
  "../../.."/[handlers/eth, misc/ticker, protocol, sync_desc, types],
  ".."/pivot,
  ../pivot/storage_queue_helper,
  ../db/[hexary_desc, snapdb_pivot],
  "../.."/[range_desc, update_beacon_header, worker_desc],
  pass_desc

logScope:
  topics = "snap-play"

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

  extraScrutinyDoubleCheckCompleteness = 1_000_000
    ## Double check database whether it is complete (debugging, testing). This
    ## action is slow and intended for debugging and testing use, only. The
    ## numeric value limits the action to the maximal number of account in the
    ## database.
    ##
    ## Set to `0` to disable.

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Snap worker " & info

template ignoreException(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    error "Exception at " & info & ":", name=($e.name), msg=(e.msg)

# --------------

proc disableWireServices(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Temporarily stop useless wire protocol services.
  ctx.ethWireCtx.txPoolEnabled = false

proc enableWireServices(ctx: SnapCtxRef) =
  ## Helper for `release()`
  ctx.ethWireCtx.txPoolEnabled = true

# --------------

proc enableRpcMagic(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Enable external pivot update via RPC
  ctx.chain.com.syncReqNewHead = ctx.pivotUpdateBeaconHeaderCB

proc disableRpcMagic(ctx: SnapCtxRef) =
  ## Helper for `release()`
  ctx.chain.com.syncReqNewHead = nil

# --------------

proc detectSnapSyncRecovery(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Initiate snap sync recovery (if any)
  let rc = ctx.pool.snapDb.pivotRecoverDB()
  if rc.isOk:
    ctx.pool.recovery = SnapRecoveryRef(state: rc.value)
    ctx.daemon = true

    # Set up early initial pivot
    ctx.pool.pivotTable.reverseUpdate(ctx.pool.recovery.state.header, ctx)
    trace logTxt "recovery started",
      checkpoint=(ctx.pool.pivotTable.topNumber.toStr & "(0)")
    if not ctx.pool.ticker.isNil:
      ctx.pool.ticker.startRecovery()

proc recoveryStepContinue(ctx: SnapCtxRef): Future[bool] {.async.} =
  let recov = ctx.pool.recovery
  if recov.isNil:
    return false

  let
    checkpoint = recov.state.header.blockNumber.toStr & "(" & $recov.level & ")"
    topLevel = recov.level == 0
    env = block:
      let rc = ctx.pool.pivotTable.eq recov.state.header.stateRoot
      if rc.isErr:
        error logTxt "recovery pivot context gone", checkpoint, topLevel
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
      trace logTxt "stale pivot, recovery stopped", checkpoint, topLevel
    return false

  # Set up next level pivot checkpoint
  ctx.pool.recovery = SnapRecoveryRef(
    state: rc.value,
    level: recov.level + 1)

  # Push onto pivot table and continue recovery (i.e. do not stop it yet)
  ctx.pool.pivotTable.reverseUpdate(ctx.pool.recovery.state.header, ctx)

  return true # continue recovery

# --------------

proc snapSyncCompleteOk(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Some global context
      ): Future[bool]
      {.async.} =
  ## Check whether this pivot is fully downloaded. The `async` part is for
  ## debugging, only and should not be used on a large database as it uses
  ## quite a bit of computation ressources.
  if env.pivotCompleteOk():
    when 0 < extraScrutinyDoubleCheckCompleteness:
      # Larger sizes might be infeasible
      if env.nAccounts <= extraScrutinyDoubleCheckCompleteness:
        if not await env.pivotVerifyComplete(ctx):
          error logTxt "inconsistent state, pivot incomplete",
            pivot=env.stateHeader.blockNumber.toStr, nAccounts=env.nAccounts
          return false
    ctx.pool.fullPivot = env
    ctx.poolMode = true # Fast sync mode must be synchronized among all peers
    return true

# ------------------------------------------------------------------------------
# Private functions, snap sync admin handlers
# ------------------------------------------------------------------------------

proc snapSyncSetup(ctx: SnapCtxRef) =
  # For snap sync book keeping
  ctx.pool.coveredAccounts = NodeTagRangeSet.init()
  ctx.pool.ticker.init(cb = ctx.pool.pivotTable.tickerStats(ctx))

  ctx.enableRpcMagic()          # Allow external pivot update via RPC
  ctx.disableWireServices()     # Stop unwanted public services
  ctx.detectSnapSyncRecovery()  # Check for recovery mode

proc snapSyncRelease(ctx: SnapCtxRef) =
  ctx.disableRpcMagic()         # Disable external pivot update via RPC
  ctx.enableWireServices()      # re-enable public services
  ctx.pool.ticker.stop()

proc snapSyncStart(buddy: SnapBuddyRef): bool =
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.snap) and
     peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    ctx.pool.ticker.startBuddy()
    buddy.ctrl.multiOk = false # confirm default mode for soft restart
    return true

proc snapSyncStop(buddy: SnapBuddyRef) =
  buddy.ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Private functions, snap sync action handlers
# ------------------------------------------------------------------------------

proc snapSyncPool(buddy: SnapBuddyRef, last: bool, laps: int): bool =
  ## Enabled when `buddy.ctrl.poolMode` is `true`
  ##
  let
    ctx = buddy.ctx
    env = ctx.pool.fullPivot

  # Check whether the snapshot is complete. If so, switch to full sync mode.
  # This process needs to be applied to all buddy peers.
  if not env.isNil:
    ignoreException("snapSyncPool"):
      # Stop all peers
      buddy.snapSyncStop()
      # After the last buddy peer was stopped switch to full sync mode
      # and repeat that loop over buddy peers for re-starting them.
      if last:
        when extraTraceMessages:
          trace logTxt "switch to full sync", peer=buddy.peer, last, laps,
            pivot=env.stateHeader.blockNumber.toStr,
            mode=ctx.pool.syncMode.active, state= buddy.ctrl.state
        ctx.snapSyncRelease()
        ctx.pool.syncMode.active = FullSyncMode
        ctx.passActor.setup(ctx)
        ctx.poolMode = true # repeat looping over peers
    return false # do stop magically when looping over peers is exhausted

  # Clean up empty pivot slots (never the top one.) This needs to be run on
  # a single peer only. So the loop can stop immediately (returning `true`)
  # after this job is done.
  var rc = ctx.pool.pivotTable.beforeLast
  while rc.isOK:
    let (key, env) = (rc.value.key, rc.value.data)
    if env.fetchAccounts.processed.isEmpty:
      ctx.pool.pivotTable.del key
    rc = ctx.pool.pivotTable.prev(key)
  true # Stop ok


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
  # External beacon header updater
  await buddy.updateBeaconHeaderFromFile()

  # Dedicate some process cycles to the recovery process (if any)
  if not buddy.ctx.pool.recovery.isNil:
    when extraTraceMessages:
      trace "Throttling single mode in favour of recovery", peer=buddy.peer
    await sleepAsync 900.milliseconds

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

  # Check whether this pivot is fully downloaded
  if await env.snapSyncCompleteOk(ctx):
    return

  # If this is a new snap sync pivot, the previous one can be cleaned up and
  # archived. There is no point in keeping some older space consuming state
  # data any longer.
  ctx.pool.pivotTable.beforeTopMostlyClean()

  let
    peer = buddy.peer
    pivot = env.stateHeader.blockNumber.toStr # for logging
    fa = env.fetchAccounts

  when extraTraceMessages:
    trace "Multi sync runner", peer, pivot, nAccounts=env.nAccounts,
      processed=fa.processed.fullPC3, nStoQ=env.storageQueueTotal(),
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
      trace logTxt "mothballing", peer, pivot, nAccounts, nSlotLists
    env.pivotMothball()
    return

  # Save state so sync can be resumed at next start up
  let rc = env.saveCheckpoint(ctx)
  if rc.isOk:
    when extraTraceMessages:
      trace logTxt "saved checkpoint", peer, pivot, nAccounts,
        processed, nStoQ=env.storageQueueTotal(),  nSlotLists,
        blobSize=rc.value
    return

  error logTxt "failed to save checkpoint", peer, pivot, nAccounts,
    processed, nStoQ=env.storageQueueTotal(), nSlotLists,
    error=rc.error

  # Check whether this pivot is fully downloaded
  discard await env.snapSyncCompleteOk(ctx)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc passSnap*: auto =
  ## Return snap sync handler environment
  PassActorRef(
    setup:   snapSyncSetup,
    release: snapSyncRelease,
    start:   snapSyncStart,
    stop:    snapSyncStop,
    pool:    snapSyncPool,
    daemon:  snapSyncDaemon,
    single:  snapSyncSingle,
    multi:   snapSyncMulti)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

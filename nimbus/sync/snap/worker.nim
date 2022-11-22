# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[hashes, options, sets, strutils],
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  ../../db/select_backend,
  ".."/[misc/best_pivot, protocol, sync_desc],
  ./worker/[pivot_helper, ticker],
  ./worker/com/com_error,
  ./worker/db/[snapdb_check, snapdb_desc],
  "."/[constants, range_desc, worker_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap-buddy"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers: integration of pivot finder
# ------------------------------------------------------------------------------

proc pivot(ctx: SnapCtxRef): BestPivotCtxRef =
  # Getter
  ctx.data.pivotFinderCtx.BestPivotCtxRef

proc `pivot=`(ctx: SnapCtxRef; val: BestPivotCtxRef) =
  # Setter
  ctx.data.pivotFinderCtx = val

proc pivot(buddy: SnapBuddyRef): BestPivotWorkerRef =
  # Getter
  buddy.data.pivotFinder.BestPivotWorkerRef

proc `pivot=`(buddy: SnapBuddyRef; val: BestPivotWorkerRef) =
  # Setter
  buddy.data.pivotFinder = val

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateSinglePivot(buddy: SnapBuddyRef): Future[bool] {.async.} =
  ## Helper, negotiate pivot unless present
  if buddy.pivot.pivotHeader.isOk:
    return true

  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotTable.lastValue.get(otherwise = nil)
    nMin = if env.isNil: none(BlockNumber)
           else: some(env.stateHeader.blockNumber)

  if await buddy.pivot.pivotNegotiate(nMin):
    var header = buddy.pivot.pivotHeader.value

    # Check whether there is no environment change needed
    when pivotEnvStopChangingIfComplete:
      let rc = ctx.data.pivotTable.lastValue
      if rc.isOk and rc.value.storageDone:
        # No neede to change
        if extraTraceMessages:
          trace "No need to change snap pivot", peer,
            pivot=("#" & $rc.value.stateHeader.blockNumber),
            stateRoot=rc.value.stateHeader.stateRoot,
            multiOk=buddy.ctrl.multiOk, runState=buddy.ctrl.state
        return true

    buddy.ctx.data.pivotTable.update(header, buddy.ctx)

    info "Snap pivot initialised", peer, pivot=("#" & $header.blockNumber),
      multiOk=buddy.ctrl.multiOk, runState=buddy.ctrl.state

    return true

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.data.coveredAccounts = NodeTagRangeSet.init()
  ctx.data.snapDb =
    if ctx.data.dbBackend.isNil: SnapDbRef.init(ctx.chain.db.db)
    else: SnapDbRef.init(ctx.data.dbBackend)
  ctx.pivot = BestPivotCtxRef.init(ctx.data.rng)
  ctx.pivot.pivotRelaxedMode(enable = true)

  if tickerOK:
    ctx.data.ticker = TickerRef.init(ctx.data.pivotTable.tickerStats(ctx))
  else:
    trace "Ticker is disabled"

  result = true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.pivot = nil
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stop()
    ctx.data.ticker = nil

proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.snap) and
     peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    buddy.pivot = BestPivotWorkerRef.init(
      buddy.ctx.pivot, buddy.ctrl, buddy.peer)
    buddy.data.errors = ComErrorStatsRef()
    if not ctx.data.ticker.isNil:
      ctx.data.ticker.startBuddy()
    return true

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  buddy.ctrl.stopped = true
  buddy.pivot.clear()
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: SnapCtxRef) {.async.} =
  ## Enabled while `ctx.daemon` is `true`
  ##
  let nPivots = ctx.data.pivotTable.len
  trace "I am the mighty recovery daemon ... stopped for now", nPivots
  # To be populated ...
  ctx.daemon = false


proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## Enabled while
  ## * `buddy.ctrl.multiOk` is `false`
  ## * `buddy.ctrl.poolMode` is `false`
  ##
  let peer = buddy.peer
  # This pivot finder one harmonises assigned difficulties of at least two
  # peers. There can only be one  `pivot2Exec()` instance active/unfinished
  # (which is wrapped into the helper function `updateSinglePivot()`.)
  if not await buddy.updateSinglePivot():
    # Wait if needed, then return => repeat
    if not buddy.ctrl.stopped:
      await sleepAsync(2.seconds)
    return

  buddy.ctrl.multiOk = true


proc runPool*(buddy: SnapBuddyRef, last: bool) =
  ## Enabled when `buddy.ctrl.poolMode` is `true`
  ##
  let ctx = buddy.ctx
  if ctx.poolMode:
    ctx.poolMode = false

    let rc = ctx.data.pivotTable.lastValue
    if rc.isOk:

      # Check whether last pivot accounts and storage are complete.
      let
        env = rc.value
        peer = buddy.peer
        pivot = "#" & $env.stateHeader.blockNumber # for logging

      if not env.storageDone:

        # Check whether accounts download is complete
        if env.fetchAccounts.unprocessed.isEmpty():

          # FIXME: This check might not be needed. It will visit *every* node
          #        in the hexary trie for checking the account leaves.
          #
          #        Note: This is insane on main net
          if buddy.checkAccountsTrieIsComplete(env):
            env.accountsState = HealerDone

            # Check whether storage slots are complete
            if env.fetchStorageFull.len == 0 and
               env.fetchStoragePart.len == 0:
              env.storageDone = true

      when extraTraceMessages:
        trace "Checked for pivot DB completeness", peer, pivot,
          nAccounts=env.nAccounts, accountsState=env.accountsState,
          nSlotLists=env.nSlotLists, storageDone=env.storageDone


proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## Enabled while
  ## * `buddy.ctrl.multiOk` is `true`
  ## * `buddy.ctrl.poolMode` is `false`
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Set up current state root environment for accounts snapshot
  let
    env = block:
      let rc = ctx.data.pivotTable.lastValue
      if rc.isErr:
        return # nothing to do
      rc.value
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  buddy.data.pivotEnv = env

  # Full sync processsing based on current snapshot
  # -----------------------------------------------
  if env.storageDone:
    if not buddy.checkAccountsTrieIsComplete(env):
      error "Ooops, all accounts fetched but DvnB still incomplete", peer, pivot

      if not buddy.checkStorageSlotsTrieIsComplete(env):
        error "Ooops, all storages fetched but DB still incomplete", peer, pivot

    trace "Snap full sync -- not implemented yet", peer, pivot
    await sleepAsync(5.seconds)
    return

  # Snapshot sync processing
  # ------------------------

  # If this is a new pivot, the previous one can be partially cleaned up.
  # There is no point in keeping some older space consuming state data any
  # longer.
  ctx.data.pivotTable.beforeTopMostlyClean()

  # This one is the syncing work horse
  let syncActionContinue = await env.execSnapSyncAction(buddy)

  # Save state so sync can be partially resumed at next start up
  block:
    let
      nMissingNodes = env.fetchAccounts.missingNodes.len
      nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len

      rc = env.saveSnapState(ctx)
    if rc.isErr:
      error "Failed to save recovery checkpoint", peer, pivot,
        nAccounts=env.nAccounts, nSlotLists=env.nSlotLists,
        nMissingNodes, nStoQu, error=rc.error
    else:
      discard
      when extraTraceMessages:
        trace "Saved recovery checkpoint", peer, pivot,
          nAccounts=env.nAccounts, nSlotLists=env.nSlotLists,
          nMissingNodes, nStoQu, blobSize=rc.value

  if not syncActionContinue:
    return

  # Check whether there are more accounts to fetch.
  #
  # Note that some other process might have temporarily borrowed from the
  # `fetchAccounts.unprocessed` list. Whether we are done can only be decided
  # if only a single buddy is active. S be it.
  if env.fetchAccounts.unprocessed.isEmpty():

    # Debugging log: analyse pivot against database
    warn "Analysing accounts database -- might be slow", peer, pivot
    discard buddy.checkAccountsListOk(env)

    # Check whether pivot download is complete.
    if env.fetchStorageFull.len == 0 and
       env.fetchStoragePart.len == 0:
      trace "Running pool mode for verifying completeness", peer, pivot
      buddy.ctx.poolMode = true

    # Debugging log: analyse pivot against database
    warn "Analysing storage slots database -- might be slow", peer, pivot
    discard buddy.checkStorageSlotsTrieIsComplete(env)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

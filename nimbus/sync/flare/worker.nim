# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.


{.push raises:[].}

import
  pkg/[chronicles, chronos],
  pkg/eth/[common, p2p],
  pkg/stew/[interval_set, sorted_set],
  ../../common,
  ./worker/[db, headers_staged, headers_unproc, start_stop, update],
  ./worker_desc

logScope:
  topics = "flare"

const extraTraceMessages = false or true
  ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc headersToFetchOk(buddy: FlareBuddyRef): bool =
  0 < buddy.ctx.headersUnprocTotal() and
    buddy.ctrl.running and
    not buddy.ctx.poolMode

proc napUnlessSomethingToFetch(
    buddy: FlareBuddyRef;
    info: static[string];
      ): Future[bool] {.async.} =
  ## When idle, save cpu cycles waiting for something to do.
  if not buddy.headersToFetchOk():
    when extraTraceMessages:
      debug info & ": idly wasting time", peer=buddy.peer
    await sleepAsync workerIdleWaitInterval
    return true
  return false

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: FlareCtxRef): bool =
  ## Global set up
  debug "RUNSETUP"
  ctx.setupRpcMagic()

  # Load initial state from database if there is any
  ctx.setupDatabase()

  # Debugging stuff, might be an empty template
  ctx.setupTicker()

  # Enable background daemon
  ctx.daemon = true
  true

proc release*(ctx: FlareCtxRef) =
  ## Global clean up
  debug "RUNRELEASE"
  ctx.destroyRpcMagic()
  ctx.destroyTicker()


proc start*(buddy: FlareBuddyRef): bool =
  ## Initialise worker peer
  const info = "RUNSTART"

  if runsThisManyPeersOnly <= buddy.ctx.pool.nBuddies:
    debug info & " peer limit reached",
      peer=buddy.peer, multiOk=buddy.ctrl.multiOk
    return false

  if not buddy.startBuddy():
    debug info & " failed", peer=buddy.peer
    return false

  buddy.ctrl.multiOk = true
  debug info, peer=buddy.peer, multiOk=buddy.ctrl.multiOk
  true

proc stop*(buddy: FlareBuddyRef) =
  ## Clean up this peer
  debug "RUNSTOP", peer=buddy.peer, nInvocations=buddy.only.nMultiLoop,
    lastIdleGap=buddy.only.multiRunIdle.toStr(2)
  buddy.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: FlareCtxRef) {.async.} =
  ## Global background job that will be re-started as long as the variable
  ## `ctx.daemon` is set `true`. If that job was stopped due to re-setting
  ## `ctx.daemon` to `false`, it will be restarted next after it was reset
  ## as `true` not before there is some activity on the `runPool()`,
  ## `runSingle()`, or `runMulti()` functions.
  ##
  const info = "RUNDAEMON"
  debug info

  # Check for a possible layout change of the `HeaderChainsSync` state
  if ctx.updateLinkedHChainsLayout():
    debug info & ": headers chain layout was updated"

  ctx.updateMetrics()
  await sleepAsync daemonWaitInterval


proc runSingle*(buddy: FlareBuddyRef) {.async.} =
  ## This peer worker is invoked if the peer-local flag `buddy.ctrl.multiOk`
  ## is set `false` which is the default mode. This flag is updated by the
  ## worker when deemed appropriate.
  ## * For all workers, there can be only one `runSingle()` function active
  ##   simultaneously for all worker peers.
  ## * There will be no `runMulti()` function active for the same worker peer
  ##   simultaneously
  ## * There will be no `runPool()` iterator active simultaneously.
  ##
  ## Note that this function runs in `async` mode.
  ##
  const info = "RUNSINGLE"
  raiseAssert info & " should not be used: peer=" & $buddy.peer


proc runPool*(buddy: FlareBuddyRef; last: bool; laps: int): bool =
  ## Once started, the function `runPool()` is called for all worker peers in
  ## sequence as the body of an iteration as long as the function returns
  ## `false`. There will be no other worker peer functions activated
  ## simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It will be automatically reset before the
  ## the loop starts. Re-setting it again results in repeating the loop. The
  ## argument `laps` (starting with `0`) indicated the currend lap of the
  ## repeated loops.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  const info = "RUNPOOL"
  when extraTraceMessages:
    debug info, peer=buddy.peer, laps
  buddy.ctx.headersStagedReorg info # reorg
  true # stop


proc runMulti*(buddy: FlareBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  const info = "RUNMULTI"
  let peer = buddy.peer

  if 0 < buddy.only.nMultiLoop:                 # statistics/debugging
    buddy.only.multiRunIdle = Moment.now() - buddy.only.stoppedMultiRun
  buddy.only.nMultiLoop.inc                     # statistics/debugging

  when extraTraceMessages:
    trace info, peer, nInvocations=buddy.only.nMultiLoop,
      lastIdleGap=buddy.only.multiRunIdle.toStr(2)

  # Update beacon header when needed. For the beacon header, a hash will be
  # auto-magically made available via RPC. The corresponding header is then
  # fetched from the current peer.
  await buddy.headerStagedUpdateBeacon info

  if not await buddy.napUnlessSomethingToFetch info:
    #
    # Layout of a triple of linked header chains (see `README.md`)
    # ::
    #   G                B                     L                F
    #   | <--- [G,B] --> | <----- (B,L) -----> | <-- [L,F] ---> |
    #   o----------------o---------------------o----------------o--->
    #   | <-- linked --> | <-- unprocessed --> | <-- linked --> |
    #
    # This function is run concurrently for fetching the next batch of
    # headers and stashing them on the database. Each concurrently running
    # actor works as follows:
    #
    # * Get a range of block numbers from the `unprocessed` range `(B,L)`.
    # * Fetch headers for this range (as much as one can get).
    # * Stash then on the database.
    # * Rinse and repeat.
    #
    # The block numbers range concurrently taken from `(B,L)` are chosen
    # from the upper range. So exactly one of the actors has a range
    # `[whatever,L-1]` adjacent to `[L,F]`. Call this actor the lead actor.
    #
    # For the lead actor, headers can be downloaded all by the hashes as
    # the parent hash for the header with block number `L` is known. All
    # other non-lead actors will download headers by the block number only
    # and stage it to be re-ordered and stashed on the database when ready.
    #
    # Once the lead actor stashes the dowloaded headers, the other staged
    # headers will also be stashed on the database until there is a gap or
    # the stashed haeders are exhausted.
    #
    # Due to the nature of the `async` logic, the current lead actor will
    # stay lead when fetching the next range of block numbers.
    #
    while buddy.headersToFetchOk():

      # * Get unprocessed range from pool
      # * Fetch headers for this range (as much as one can get)
      # * Verify that a block is contiguous, chained by parent hash, etc.
      # * Stash this range on the staged queue on the pool
      if await buddy.headersStagedCollect info:

        # * Save updated state and headers
        # * Decrease the left boundary `L` of the trusted range `[L,F]`
        discard buddy.ctx.headersStagedProcess info

    # Note that it is important **not** to leave this function to be
    # re-invoked by the scheduler unless necessary. While the time gap
    # until restarting is typically a few millisecs, there are always
    # outliers which well exceed several seconds. This seems to let
    # remote peers run into timeouts.

  buddy.only.stoppedMultiRun = Moment.now()     # statistics/debugging

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

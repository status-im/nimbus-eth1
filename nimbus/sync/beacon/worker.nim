# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ./worker/update/[metrics, ticker],
  ./worker/[blocks_staged, headers_staged, headers_unproc, start_stop, update],
  ./worker_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc headersToFetchOk(buddy: BeaconBuddyRef): bool =
  0 < buddy.ctx.headersUnprocAvail() and
    buddy.ctrl.running and
    not buddy.ctx.poolMode

proc bodiesToFetchOk(buddy: BeaconBuddyRef): bool =
  buddy.ctx.blocksStagedFetchOk() and
    buddy.ctrl.running and
    not buddy.ctx.poolMode

proc napUnlessSomethingToFetch(
    buddy: BeaconBuddyRef;
      ): Future[bool] {.async: (raises: []).} =
  ## When idle, save cpu cycles waiting for something to do.
  if buddy.ctx.pool.blockImportOk or             # currently importing blocks
     buddy.ctx.hibernate or                      # not activated yet?
     not (buddy.headersToFetchOk() or            # something on TODO list
          buddy.bodiesToFetchOk()):
    try:
      await sleepAsync workerIdleWaitInterval
    except CancelledError:
      buddy.ctrl.zombie = true
    return true
  else:
    # Returning `false` => no need to check for shutdown
    return false

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Global set up
  ctx.setupServices info

  # Load initial state from database if there is any
  ctx.setupDatabase info
  true

proc release*(ctx: BeaconCtxRef; info: static[string]) =
  ## Global clean up
  ctx.destroyServices()


proc start*(buddy: BeaconBuddyRef; info: static[string]): bool =
  ## Initialise worker peer
  let peer = buddy.peer

  if runsThisManyPeersOnly <= buddy.ctx.pool.nBuddies:
    if not buddy.ctx.hibernate: debug info & ": peers limit reached", peer
    return false

  if not buddy.startBuddy():
    if not buddy.ctx.hibernate: debug info & ": failed", peer
    return false

  if not buddy.ctx.hibernate: debug info & ": new peer", peer
  true

proc stop*(buddy: BeaconBuddyRef; info: static[string]) =
  ## Clean up this peer
  if not buddy.ctx.hibernate: debug info & ": release peer", peer=buddy.peer,
    ctrl=buddy.ctrl.state, nLaps=buddy.only.nMultiLoop,
    lastIdleGap=buddy.only.multiRunIdle.toStr
  buddy.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runTicker*(ctx: BeaconCtxRef; info: static[string]) =
  ## Global background job that is started every few seconds. It is to be
  ## intended for updating metrics, debug logging etc.
  ctx.updateMetrics()
  ctx.updateTicker()

proc runDaemon*(
    ctx: BeaconCtxRef;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Global background job that will be re-started as long as the variable
  ## `ctx.daemon` is set `true`.
  ##
  ## On a fresh start, the flag `ctx.daemon` will not be set `true` before the
  ## first usable request from the CL (via RPC) stumbles in.
  ##
  # Check for a possible header layout and body request changes
  ctx.updateSyncState info
  if ctx.hibernate:
    return

  # Execute staged block records.
  if ctx.blocksStagedCanImportOk():

    block:
      # Set advisory flag telling that a slow/long running process will take
      # place. So there might be some peers active. If they are waiting for
      # a message reply, this will most probably time out as all processing
      # power is usurped by the import task here.
      ctx.pool.blockImportOk = true
      defer: ctx.pool.blockImportOk = false

      # Import from staged queue.
      while await ctx.blocksStagedImport(info):
        if not ctx.daemon or   # Implied by external sync shutdown?
           ctx.poolMode:       # Oops, re-org needed?
          return

  # At the end of the cycle, leave time to trigger refill headers/blocks
  try: await sleepAsync daemonWaitInterval
  except CancelledError: discard


proc runPool*(
    buddy: BeaconBuddyRef;
    last: bool;
    laps: int;
    info: static[string];
      ): bool =
  ## Once started, the function `runPool()` is called for all worker peers in
  ## sequence as long as this function returns `false`. There will be no other
  ## `runPeer()` functions activated while `runPool()` is active.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) The flag will be automatically reset before
  ## the loop starts. Re-setting it again results in repeating the loop. The
  ## argument `laps` (starting with `0`) indicated the currend lap of the
  ## repeated loops.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  buddy.ctx.headersStagedReorg info
  buddy.ctx.blocksStagedReorg info
  true # stop


proc runPeer*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ) {.async: (raises: []).} =
  ## This peer worker method is repeatedly invoked (exactly one per peer) while
  ## the `buddy.ctrl.poolMode` flag is set `false`.
  ##
  if 0 < buddy.only.nMultiLoop:                 # statistics/debugging
    buddy.only.multiRunIdle = Moment.now() - buddy.only.stoppedMultiRun
  buddy.only.nMultiLoop.inc                     # statistics/debugging

  # Update consensus header target when needed. It comes with a finalised
  # header hash where we need to complete the block number.
  await buddy.headerStagedUpdateTarget info

  if not await buddy.napUnlessSomethingToFetch():
    #
    # Layout of a triple of linked header chains (see `README.md`)
    # ::
    #   0                C                     D                H
    #   | <--- [0,C] --> | <----- (C,D) -----> | <-- [D,H] ---> |
    #   o----------------o---------------------o----------------o--->
    #   | <-- linked --> | <-- unprocessed --> | <-- linked --> |
    #
    # This function is run concurrently for fetching the next batch of
    # headers and stashing them on the database. Each concurrently running
    # actor works as follows:
    #
    # * Get a range of block numbers from the `unprocessed` range `(C,D)`.
    # * Fetch headers for this range (as much as one can get).
    # * Stash then on the database.
    # * Rinse and repeat.
    #
    # The block numbers range concurrently taken from `(C,D)` are chosen
    # from the upper range. So exactly one of the actors has a range
    # `[whatever,D-1]` adjacent to `[D,H]`. Call this actor the lead actor.
    #
    # For the lead actor, headers can be downloaded all by the hashes as
    # the parent hash for the header with block number `D` is known. All
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
        # * Decrease the dangling left boundary `D` of the trusted range `[D,H]`
        discard buddy.ctx.headersStagedProcess info

    # Fetch bodies and combine them with headers to blocks to be staged. These
    # staged blocks are then excuted by the daemon process (no `peer` needed.)
    while buddy.bodiesToFetchOk():
      discard await buddy.blocksStagedCollect info

    # Note that it is important **not** to leave this function to be
    # re-invoked by the scheduler unless necessary. While the time gap
    # until restarting is typically a few millisecs, there are always
    # outliers which well exceed several seconds. This seems to let
    # remote peers run into timeouts.

  buddy.only.stoppedMultiRun = Moment.now()     # statistics/debugging

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

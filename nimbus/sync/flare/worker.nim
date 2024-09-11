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
  ./worker/[db, staged, start_stop, unproc, update],
  ./worker_desc

logScope:
  topics = "flare"

const extraTraceMessages = false or true
  ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc headersToFetchOk(buddy: FlareBuddyRef): bool =
  0 < buddy.ctx.unprocTotal() and buddy.ctrl.running and not buddy.ctx.poolMode

proc napUnlessHeadersToFetch(
    buddy: FlareBuddyRef;
    info: static[string];
      ): Future[bool] {.async.} =
  ## When idle, save cpu cycles waiting for something to do.
  let ctx = buddy.ctx
  if not buddy.headersToFetchOk():
    when extraTraceMessages:
      debug info & ": idle wasting time", peer=buddy.peer
    await sleepAsync runNoHeadersIdleWaitInterval
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
  ctx.dbLoadLinkedHChainsLayout()

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

  when runOnSinglePeerOnly:
    if 0 < buddy.ctx.pool.nBuddies:
      debug info & " single peer already connected",
        peer=buddy.peer, multiOk=buddy.ctrl.multiOk
      return false

  if not buddy.startBuddy():
    debug info & " failed", peer=buddy.peer
    return false

  when not runOnSinglePeerOnly:
    buddy.ctrl.multiOk = true
  debug info, peer=buddy.peer, multiOk=buddy.ctrl.multiOk
  true


proc stop*(buddy: FlareBuddyRef) =
  ## Clean up this peer
  debug "RUNSTOP", peer=buddy.peer
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
  when not runOnSinglePeerOnly:
    raiseAssert info & " should not be used: peer=" & $buddy.peer

  else:
    if not await buddy.napUnlessHeadersToFetch info:
      # See `runMulti()` for comments
      while buddy.headersToFetchOk():
        if await buddy.stagedCollect info:
          discard buddy.ctx.stagedProcess info


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
  buddy.ctx.stagedReorg info # reorg
  true # stop


proc runMulti*(buddy: FlareBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  const info = "RUNMULTI"
  when runOnSinglePeerOnly:
    raiseAssert info & " should not be used: peer=" & $buddy.peer

  else:
    let
      ctx = buddy.ctx
      peer = buddy.peer

    if await buddy.napUnlessHeadersToFetch info:
      return

    if not ctx.flipCoin():
      # Come back next time
      when extraTraceMessages:
        debug info & ": running later", peer
      return

    # * get unprocessed range from pool
    # * fetch headers for this range (as much as one can get)
    # * verify that a block is sound, i.e. contiguous, chained by parent hashes
    # * return remaining range to unprocessed range in the pool
    # * store this range on the staged queue on the pool
    if await buddy.stagedCollect info:
      # * increase the top/right interval of the trused range `[L,F]`
      # * save updated state and headers
      discard buddy.ctx.stagedProcess info

    else:
      when extraTraceMessages:
        debug info & ": nothing fetched, done", peer

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
  if buddy.startBuddy():
    buddy.ctrl.multiOk = true
    debug "RUNSTART", peer=buddy.peer, multiOk=buddy.ctrl.multiOk
    return true
  debug "RUNSTART failed", peer=buddy.peer

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
  raiseAssert "RUNSINGLE should not be used: peer=" & $buddy.peer


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
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if ctx.unprocTotal() == 0 and ctx.stagedChunks() == 0:
    # Save cpu cycles waiting for something to do
    when extraTraceMessages:
      debug info & ": idle wasting time", peer
    await sleepAsync runMultiIdleWaitInterval
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

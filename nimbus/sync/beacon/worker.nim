# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  chronicles,
  chronos,
  eth/p2p,
  ".."/[protocol, sync_desc],
  ./worker_desc

logScope:
  topics = "beacon-buddy"

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

  FirstPivotSeenTimeout = 3.minutes
    ## Turn on relaxed pivot negotiation after some waiting time when there
    ## was a `peer` seen but was rejected. This covers a rare event. Typically
    ## useless peers do not appear ready for negotiation.

  FirstPivotAcceptedTimeout = 50.seconds
    ## Turn on relaxed pivot negotiation after some waiting time when there
    ## was a `peer` accepted but no second one yet.

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc pp(n: BlockNumber): string =
  ## Dedicated pretty printer (`$` is defined elsewhere using `UInt256`)
  if n == high(BlockNumber): "high" else:"#" & $n

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: BeaconCtxRef): bool =
  ## Global set up
  #ctx.pool.pivot = BestPivotCtxRef.init(ctx.pool.rng)

  true

proc release*(ctx: BeaconCtxRef) =
  ## Global clean up
  #ctx.pool.pivot = nil

proc start*(buddy: BeaconBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:

    ctx.daemon = true
    return true

proc stop*(buddy: BeaconBuddyRef) =
  ## Clean up this peer
  buddy.ctrl.stopped = true


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: BeaconCtxRef) {.async.} =
  ## Global background job that will be re-started as long as the variable
  ## `ctx.daemon` is set `true`. If that job was stopped due to re-setting
  ## `ctx.daemon` to `false`, it will be restarted next after it was reset
  ## as `true` not before there is some activity on the `runPool()`,
  ## `runSingle()`, or `runMulti()` functions.
  ##

  debugEcho "RUNDAEMON: ", ctx.pool.id
  ctx.daemon = false

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.) Larger waiting time cleans up logging.
  await sleepAsync 300.milliseconds


proc runSingle*(buddy: BeaconBuddyRef) {.async.} =
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
  let
    ctx = buddy.ctx
    peer {.used.} = buddy.peer

  debugEcho "RUNSINGLE: ", ctx.pool.id

  if buddy.ctrl.stopped:
    when extraTraceMessages:
      trace "Single mode stopped", peer, pivotState=ctx.pool.pivotState
    return # done with this buddy

  var napping = 2.seconds
  when extraTraceMessages:
    trace "Single mode end", peer, napping

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.)
  await sleepAsync napping


proc runPool*(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  ## Once started, the function `runPool()` is called for all worker peers in
  ## sequence as the body of an iteration as long as the function returns
  ## `false`. There will be no other worker peer functions activated
  ## simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It will be automatically reset before the
  ## the loop starts. Re-setting it again results in repeating the loop. The
  ## argument `lap` (starting with `0`) indicated the currend lap of the
  ## repeated loops.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  let
    ctx = buddy.ctx

  debugEcho "RUNPOOL: ", ctx.pool.id

  true # Stop after running once regardless of peer

proc runMulti*(buddy: BeaconBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  let
    ctx = buddy.ctx

  debugEcho "RUNMULTI: ", ctx.pool.id

  # Update persistent database
  #while not buddy.ctrl.stopped:
    # Allow thread switch as `persistBlocks()` might be slow
  await sleepAsync(10.milliseconds)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

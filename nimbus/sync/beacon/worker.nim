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
  chronos/timer,
  eth/p2p,
  ".."/[protocol, sync_desc],
  ./worker_desc,
  ./skeleton_main,
  ./skeleton_utils,
  ./beacon_impl

logScope:
  topics = "beacon-buddy"

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: BeaconCtxRef): bool =
  ## Global set up
  ctx.pool.mask = IntervalSetRef[uint64, uint64].init()
  ctx.pool.pulled = IntervalSetRef[uint64, uint64].init()
  ctx.pool.skeleton = SkeletonRef.new(ctx.chain)
  let res = ctx.pool.skeleton.open()
  if res.isErr:
    error "Cannot open beacon skeleton", msg=res.error
    return false

  ctx.pool.mode.incl bmResumeSync
  true

proc release*(ctx: BeaconCtxRef) =
  ## Global clean up
  discard

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

  debug "RUNDAEMON", id=ctx.pool.id

  # Just wake up after long sleep (e.g. client terminated)
  if bmResumeSync in ctx.pool.mode:
    let ok = await ctx.resumeSync()
    ctx.pool.mode.excl bmResumeSync

  # We get order from engine API
  if ctx.pool.target.len > 0:
    await ctx.setSyncTarget()

  # Distributing jobs of filling gaps to peers
  let mask = ctx.pool.mask
  for x in mask.decreasing:
    ctx.fillBlocksGaps(x.minPt, x.maxPt)

  # Tell the `runPool` to grab job for each peer
  if ctx.pool.jobs.len > 0:
    ctx.poolMode = true

  # Rerun this function next iteration
  # if there are more new sync target
  ctx.daemon = ctx.pool.target.len > 0

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.) Larger waiting time cleans up logging.
  var sleepDuration = timer.milliseconds(300)
  if ctx.pool.jobs.len == 0 and ctx.pool.target.len == 0:
    sleepDuration = timer.seconds(5)
    
  await sleepAsync sleepDuration


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

  debug "RUNSINGLE", id=ctx.pool.id

  if buddy.ctrl.stopped:
    when extraTraceMessages:
      trace "Single mode stopped", peer, pivotState=ctx.pool.pivotState
    return # done with this buddy

  var napping = timer.seconds(2)
  when extraTraceMessages:
    trace "Single mode end", peer, napping

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.)
  await sleepAsync napping

  # request new jobs, if available
  if ctx.pool.jobs.len == 0:
    ctx.daemon = true


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

  debug "RUNPOOL", id=ctx.pool.id

  # If a peer cannot finish it's job,
  # we will put it back into circulation.
  # A peer can also spawn more jobs.
  if buddy.only.requeue.len > 0:
    for job in buddy.only.requeue:
      ctx.pool.jobs.addLast(job)
    buddy.only.requeue.setLen(0)
    buddy.only.job = nil

  # Take distributed jobs for each peer
  if ctx.pool.jobs.len > 0 and buddy.only.job.isNil:
    buddy.only.job = ctx.pool.jobs.popFirst()
    buddy.ctrl.multiOk = true

  # If there is no more jobs, stop
  ctx.pool.jobs.len == 0


proc runMulti*(buddy: BeaconBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  let
    ctx = buddy.ctx

  debug "RUNMULTI", id=ctx.pool.id

  # If each of peers get their job,
  # execute it until failure or success
  # It is also possible to spawn more jobs
  if buddy.only.job.isNil.not:
    await buddy.executeJob(buddy.only.job)

  # Update persistent database
  #while not buddy.ctrl.stopped:
    # Allow thread switch as `persistBlocks()` might be slow
  await sleepAsync timer.milliseconds(10)

  # request new jobs, if available
  if ctx.pool.jobs.len == 0:
    ctx.daemon = true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../../common,
  ../../networking/p2p,
  ./worker/headers/headers_target,
  ./worker/update/metrics,
  ./worker/[blocks, classify, headers, start_stop, update, worker_desc]

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Global set up
  ctx.setupServices info
  true

proc release*(ctx: BeaconCtxRef; info: static[string]) =
  ## Global clean up
  ctx.destroyServices()


proc start*(buddy: BeaconBuddyRef; info: static[string]): bool =
  ## Initialise worker peer
  let
    peer = buddy.peer
    ctx = buddy.ctx

  if not ctx.pool.seenData and buddy.peerID in ctx.pool.failedPeers:
    if not ctx.hibernate: debug info & ": useless peer already tried", peer
    return false

  if not buddy.startBuddy():
    if not ctx.hibernate: debug info & ": failed", peer
    return false

  if not ctx.hibernate: debug info & ": new peer",
    peer, nSyncPeers=ctx.pool.nBuddies
  true

proc stop*(buddy: BeaconBuddyRef; info: static[string]) =
  ## Clean up this peer
  if not buddy.ctx.hibernate: debug info & ": release peer", peer=buddy.peer,
    thPut=buddy.only.thPutStats.toMeanVar.psStr,
    nSyncPeers=(buddy.ctx.pool.nBuddies-1), state=($buddy.syncState)
  buddy.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runTicker*(ctx: BeaconCtxRef; info: static[string]) =
  ## Global background job that is started every few seconds. It is to be
  ## intended for updating metrics, debug logging etc.
  ##
  ctx.updateMetrics()
  ctx.pool.ticker(ctx)

  # Inform if there are no peers active while syncing
  if not ctx.hibernate and ctx.pool.nBuddies < 1:
    let now = Moment.now()
    if ctx.pool.lastNoPeersLog + noPeersLogWaitInterval < now:
      ctx.pool.lastNoPeersLog = now
      debug info & ": no sync peers yet",
        ela=(now - ctx.pool.lastPeerSeen).toStr,
        nOtherPeers=ctx.node.peerPool.connectedNodes.len


template runDaemon*(ctx: BeaconCtxRef; info: static[string]): Duration =
  ## Async/template
  ##
  ## Global background job that will be re-started as long as the variable
  ## `ctx.daemon` is set `true` which corresponds to `ctx.hibernating` set
  ## to false.
  ##
  ## On a fresh start, the flag `ctx.daemon` will not be set `true` before the
  ## first usable request from the CL (via RPC) stumbles in.
  ##
  ## The template returns a suggested idle time for after this task.
  ##
  var bodyRc = chronos.nanoseconds(0)
  block body:
    # Update syncer state.
    ctx.updateSyncState info

    # Extra waiting time unless immediate change expected.
    if ctx.pool.lastState in {headers,blocks}:
      bodyRc = daemonWaitInterval

  bodyRc


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


template runPeer*(
    buddy: BeaconBuddyRef;
    rank: PeerRanking;
    info: static[string];
      ): Duration =
  ## Async/template
  ##
  ## This peer worker method is repeatedly invoked (exactly one per peer) while
  ## the `buddy.ctrl.poolMode` flag is set `false`.
  ##
  ## The template returns a suggested idle time for after this task.
  ##
  var bodyRc = chronos.nanoseconds(0)
  block body:
    if buddy.somethingToCollectOrUnstage():

      trace info & ": start processing", peer=buddy.peer,
        thPut=buddy.only.thPutStats.toMeanVar.psStr,
        rankInfo=($rank.assessed),
        rank=(if rank.ranking < 0: "n/a" else: $rank.ranking),
        nSyncPeers=buddy.ctx.pool.nBuddies, state=($buddy.syncState)

      if rank.assessed == rankingTooLow:
        # Tell the scheduler to wait a bit longer before next invocation.
        # The reasoning is that in case of a low rank labelling, all slots
        # for peers downloading can be filled with higher ranking peers. And
        # this situation would not change immediately.
        bodyRc = workerIdleLongWaitInterval
        break body                                # done, exit

      # Download and process headers and blocks
      block downloadAndProcess:
        while buddy.headersCollectOk():

          # Collect headers and either stash them on the header chain cache
          # directly, or stage on the header queue to get them serialised and
          # stashed, later.
          buddy.headersCollect info               # async/template

          # Store serialised headers from the `staged` queue onto the header
          # chain cache.
          if not buddy.headersUnstage info:       # async/template
            # Need to proceed with another peer (e.g. gap between queue and
            # header chain cache.)
            bodyRc = workerIdleWaitInterval
            break downloadAndProcess

          # End `while()`

        # Fetch bodies and combine them with headers to blocks to be staged.
        # These staged blocks are then excuted by the daemon process (no `peer`
        # needed.)
        while buddy.blocksCollectOk():
          # Collect bodies and either import them via `FC` module, or stage on
          # the blocks queue to get them serialised and imported, later.
          buddy.blocksCollect info                # async/template

          # Import bodies from the `staged` queue.
          if not buddy.blocksUnstage info:        # async/template
            # Need to proceed with another peer (e.g. gap between top imported
            # block and blocks queue.)
            bodyRc = workerIdleWaitInterval
            break downloadAndProcess

          # End `while()`

      # End block: `actionLoop`

    elif buddy.ctx.pool.lastState == SyncState.idle:
      # Potentially a manual sync target set up
      if not buddy.headersTargetActivate info:
        bodyRc = workerIdleLongWaitInterval
      break body

    # Idle sleep unless there is something to do
    if not buddy.somethingToCollectOrUnstage():
      bodyRc = workerIdleWaitInterval

    # End block: `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

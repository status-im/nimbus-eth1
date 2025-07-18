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
  std/[strutils, syncio],
  pkg/[chronicles, chronos],
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../../common,
  ./worker/update/[metrics, ticker],
  ./worker/[blocks, headers, start_stop, update],
  ./worker_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc somethingToCollect(buddy: BeaconBuddyRef): bool =
  if buddy.ctx.hibernate:                        # not activated yet?
    return false
  if buddy.headersCollectOk() or                 # something on TODO list
     buddy.blocksCollectOk():
    return true
  false

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
    nSyncPeers=(buddy.ctx.pool.nBuddies-1), syncState=($buddy.syncState)
  buddy.stopBuddy()

# --------------------

proc initalTargetFromFile*(
    ctx: BeaconCtxRef;
    file: string;
    info: static[string];
      ): Result[void,string] =
  ## Set up inital sprint from argument file (itended for debugging)
  try:
    var f = file.open(fmRead)
    defer: f.close()
    var rlp = rlpFromHex(f.readAll().splitWhitespace.join)
    ctx.pool.clReq = rlp.read(SyncClMesg)
  except CatchableError as e:
    return err("Error decoding file: \"" & file & "\"" &
      " (" & $e.name & ": " & e.msg & ")")
  ok()

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
  ## `ctx.daemon` is set `true` which corresponds to `ctx.hibernating` set
  ## to false.
  ##
  ## On a fresh start, the flag `ctx.daemon` will not be set `true` before the
  ## first usable request from the CL (via RPC) stumbles in.
  ##
  # Check for a possible header layout and body request changes
  ctx.updateSyncState info
  if ctx.hibernate:
    return

  # Execute staged block records.
  if ctx.blocksUnstageOk():

    # Import bodies from the `staged` queue.
    discard await ctx.blocksUnstage info

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
  if buddy.somethingToCollect():

    # Download and process headers and blocks
    while buddy.headersCollectOk():

      # Collect headers and either stash them on the header chain cache
      # directly, or stage on the header queue to get them serialised and
      # stashed, later.
      await buddy.headersCollect info

      # Store serialised headers from the `staged` queue onto the header
      # chain cache.
      if not buddy.headersUnstage info:
        # Need to proceed with another peer (e.g. gap between queue and
        # header chain cache.)
        break

      # End `while()`

    # Fetch bodies and combine them with headers to blocks to be staged. These
    # staged blocks are then excuted by the daemon process (no `peer` needed.)
    while buddy.blocksCollectOk():

      # Collect bodies and either import them via `FC` module, or stage on
      # the blocks queue to get them serialised and imported, later.
      await buddy.blocksCollect info

      # Import bodies from the `staged` queue.
      if not await buddy.blocksUnstage info:
        # Need to proceed with another peer (e.g. gap between top imported
        # block and blocks queue.)
        break

      # End `while()`

  # Idle sleep unless there is something to do
  if not buddy.somethingToCollect():
    try: await sleepAsync workerIdleWaitInterval
    except CancelledError: discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

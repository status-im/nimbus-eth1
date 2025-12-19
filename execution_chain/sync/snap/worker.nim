# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  ./worker/worker_desc

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; info: static[string]): bool =
  ## Global set up
  true

proc release*(ctx: SnapCtxRef; info: static[string]) =
  ## Global clean up
  discard

proc start*(buddy: SnapPeerRef; info: static[string]): bool =
  ## Initialise worker peer
  true

proc stop*(buddy: SnapPeerRef; info: static[string]) =
  ## Clean up this peer
  discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runTicker*(ctx: SnapCtxRef; info: static[string]) =
  ## Global background job that is started every few seconds. It is to be
  ## intended for updating metrics, debug logging etc.
  ##
  discard

template runDaemon*(ctx: SnapCtxRef; info: static[string]): Duration =
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
  debug info & ": not implemented for snap sync", nSyncPeers=ctx.nSyncPeers()
  chronos.seconds(10)

proc runPool*(
    buddy: SnapPeerRef;
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
  debug info & ": not implemented for snap sync", peer=buddy.peer,
    nSyncPeers=buddy.ctx.nSyncPeers()
  true # stop

template runPeer*(
    buddy: SnapPeerRef;
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
  debug info & ": not implemented for snap sync", peer=buddy.peer,
    nSyncPeers=buddy.ctx.nSyncPeers()
  chronos.seconds(10)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

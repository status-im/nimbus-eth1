# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/os,
  pkg/[chronicles, chronos, minilru, results],
  ./worker/[account, helpers, start_stop, state_db, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; info: static[string]): bool =
  ## Global set up
  ctx.setupServices info

proc release*(ctx: SnapCtxRef; info: static[string]) =
  ## Global clean up
  ctx.destroyServices()


proc start*(buddy: SnapPeerRef; info: static[string]): bool =
  ## Initialise worker peer
  let
    peer {.inject,used.} = $buddy.peer              # logging only
    ctx = buddy.ctx

  if not ctx.pool.seenData and buddy.peerID in ctx.pool.failedPeers:
    debug info & ": useless peer already tried", peer
    return false

  if not buddy.startSyncPeer():
    debug info & ": failed", peer
    return false

  debug info & ": new peer", peer, nSyncPeers=ctx.nSyncPeers(),
    peerType=buddy.only.peerType, clientId=buddy.peer.clientId
  true

proc stop*(buddy: SnapPeerRef; info: static[string]) =
  ## Clean up this peer
  debug info & ": release peer", peer=buddy.peer,
    nSyncPeers=(buddy.ctx.nSyncPeers()-1), state=($buddy.syncState)
  buddy.stopSyncPeer()

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
  debug info & ": snap sync not implemented yet", nSyncPeers=ctx.nSyncPeers()
  chronos.seconds(30)

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
  debug info & ": snap sync not implemented yet", peer=buddy.peer,
    nSyncPeers=buddy.ctx.nSyncPeers()
  true # stop

template runPeer*(
    buddy: SnapPeerRef;
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
    let
      ctx = buddy.ctx
      peer {.inject,used.} = $buddy.peer            # logging only

    buddy.accountRangeImport info

    debug info & ": snap sync not implemented yet", peer,
      nSyncPeers=ctx.nSyncPeers()

    bodyRc = chronos.seconds(10)
    # End block: `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

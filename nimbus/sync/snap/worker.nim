# Nimbus
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[options, sets, strutils],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  ".."/[protocol, sync_desc],
  ./worker/[fetch, pivot, ticker],
  ./worker_desc

logScope:
  topics = "snap-sync"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateStateRoot(buddy: SnapBuddyRef): bool =
  ## Update global state root header `stateHeader` from worker peer
  ## `pivotHeader`. Choose the latest block number. Returns `true` if the
  ## `stateHeader` was changed.
  if buddy.data.pivotHeader.isSome:
    let
      ctx = buddy.ctx
      pivotNumber = buddy.data.pivotHeader.unsafeGet.blockNumber
      stateNumber = if ctx.data.stateHeader.isNone: 0.toBlockNumber
                    else: ctx.data.stateHeader.unsafeGet.blockNumber
    if stateNumber < pivotNumber:
      ctx.data.stateHeader = buddy.data.pivotHeader
      return true

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.fetchSetup()
  if tickerOK:
    ctx.data.ticker = TickerRef.init(ctx.tickerUpdate)
  else:
    trace "Ticker is disabled"
  true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.fetchRelease()
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stop()
    ctx.data.ticker = nil

proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.snap) and
     peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    buddy.pivotStart()
    buddy.fetchStart()
    if not ctx.data.ticker.isNil:
      ctx.data.ticker.startBuddy()
    return true

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  buddy.ctrl.stopped = true
  buddy.fetchStop()
  buddy.pivotStop()
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runSingle*(buddy: SnapBuddyRef) {.async.} =
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
    peer = buddy.peer
  trace "Worker runSingle()", peer
  await buddy.pivotExec()
  if buddy.updateStateRoot():
    buddy.ctrl.multiOk = true
  elif buddy.data.pivotHeader.isSome:
    # OK, for now
    buddy.ctrl.multiOk = true

proc runPool*(buddy: SnapBuddyRef) =
  ## Ocne started, the function `runPool()` is called for all worker peers in
  ## a row (as the body of an iteration.) There will be no other worker peer
  ## functions activated simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It is the responsibility of the `runPool()`
  ## instance to reset the flag `buddy.ctx.poolMode`, typically at the first
  ## peer instance as the number of active instances is unknown to `runPool()`.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  discard

proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  let peer = buddy.peer
  trace "Starting worker runMulti()", peer
  await buddy.fetchExec()
  trace "Done worker runMulti()", peer

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

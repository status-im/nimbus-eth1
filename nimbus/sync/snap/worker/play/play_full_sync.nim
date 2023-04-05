# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles,
  chronos,
  eth/p2p,
  ../../../sync_desc,
  ../../worker_desc,
  play_desc

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private functions, full sync handlers
# ------------------------------------------------------------------------------

proc fullSyncPool(buddy: SnapBuddyRef, last: bool): bool =
  buddy.ctx.poolMode = false
  true

proc fullSyncDaemon(ctx: SnapCtxRef) {.async.} =
  ctx.daemon = false

proc fullSyncSingle(buddy: SnapBuddyRef) {.async.} =
  buddy.ctrl.multiOk = true

proc fullSyncMulti(buddy: SnapBuddyRef): Future[void] {.async.} =
  ## Full sync processing
  let
    ctx = buddy.ctx
    peer = buddy.peer

  trace "Snap full sync -- not implemented yet", peer
  await sleepAsync(5.seconds)

  # flip over to single mode for getting new instructins
  buddy.ctrl.multiOk = false

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc playFullSyncSpecs*: PlaySyncSpecs =
  ## Return full sync handler environment
  PlaySyncSpecs(
    pool:   fullSyncPool,
    daemon: fullSyncDaemon,
    single: fullSyncSingle,
    multi:  fullSyncMulti)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

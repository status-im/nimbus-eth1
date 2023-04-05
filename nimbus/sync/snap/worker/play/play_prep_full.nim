#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Transitional handlers preparing for full sync

{.push raises: [].}

import
  chronicles,
  chronos,
  eth/p2p,
  stew/keyed_queue,
  ../../../sync_desc,
  ../../worker_desc,
  play_desc

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private functions, transitional handlers preparing for full sync
# ------------------------------------------------------------------------------

proc prepFullSyncPool(buddy: SnapBuddyRef, last: bool): bool =
  buddy.ctx.poolMode = false
  true

proc prepFullSyncDaemon(ctx: SnapCtxRef) {.async.} =
  ctx.daemon = false

proc prepFullSyncSingle(buddy: SnapBuddyRef) {.async.} =
  ## One off, setting up full sync processing in single mode
  let
    ctx = buddy.ctx

    # Fetch latest state root environment
    env = block:
      let rc = ctx.pool.pivotTable.lastValue
      if rc.isErr:
        buddy.ctrl.multiOk = false
        return
      rc.value

    peer = buddy.peer
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  when extraTraceMessages:
    trace "Full sync prepare in single mode", peer, pivot

  ctx.playMode = FullSyncMode
  buddy.ctrl.multiOk = true


proc prepFullSyncMulti(buddy: SnapBuddyRef): Future[void] {.async.} =
  ## One off, setting up full sync processing in single mode
  buddy.ctrl.multiOk = false

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc playPrepFullSpecs*: PlaySyncSpecs =
  ## Return full sync preparation handler environment
  PlaySyncSpecs(
    pool:   prepFullSyncPool,
    daemon: prepFullSyncDaemon,
    single: prepFullSyncSingle,
    multi:  prepFullSyncMulti)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

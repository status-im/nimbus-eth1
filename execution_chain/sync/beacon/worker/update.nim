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
  std/sets,
  pkg/[chronicles, chronos, metrics],
  pkg/eth/common,
  ./blocks/blocks_unproc,
  ./update/[update_eta, update_metrics],
  ./[headers, worker_desc]

export
  update_eta, update_metrics

logScope:
  topics = "beacon sync"

declareGauge nec_sync_last_block_imported, "" &
  "last block successfully imported/executed by FC module"

declareGauge nec_sync_head, "" &
  "Current sync target block number (if any)"

# ------------------------------------------------------------------------------
# Private functions, state handler helpers
# ------------------------------------------------------------------------------

proc commitCollectHeaders(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Link header chain into `FC` module. Gets ready for block import.
  ##
  # This function does the job linking into `FC` module proper
  ctx.hdrCache.commit().isOkOr:
    trace info & ": cannot finalise header chain",
      B=ctx.chain.baseNumber, L=ctx.chain.latestNumber,
      D=ctx.hdrCache.antecedent.number, H=ctx.hdrCache.head.number,
      `error`=error
    return false

  true

proc setupProcessingBlocks(ctx: BeaconCtxRef; info: static[string]) =
  ## Prepare for blocks processing
  ##
  # Reset for useles block download detection (to avoid deadlock)
  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false

  # Re-initialise sub-state variables
  ctx.subState.topNum = ctx.hdrCache.antecedent.number - 1
  ctx.subState.headNum = ctx.hdrCache.head.number
  ctx.subState.headHash = ctx.hdrCache.headHash

  metrics.set(nec_sync_last_block_imported, ctx.subState.topNum.int64)
  metrics.set(nec_sync_head, ctx.subState.headNum.int64)

  # Update list of block numbers to process
  ctx.blocksUnprocSet(ctx.subState.topNum + 1, ctx.subState.headNum)

# ------------------------------------------------------------------------------
# Private state transition handlers
# ------------------------------------------------------------------------------

func idleNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.hdrCache.state == collecting:
    return SyncState.headers
  idle

proc headersNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if not ctx.pool.seenData and         # checks for cul-de-sac syncing
     nFetchHeadersFailedInitialPeersThreshold < ctx.pool.failedPeers.len:
    debug info & ": too many failed header peers",
      failedPeers=ctx.pool.failedPeers.len,
      limit=nFetchHeadersFailedInitialPeersThreshold
    return headersCancel

  if ctx.subState.cancelRequest:
    return headersCancel

  if ctx.hdrCache.state == collecting:
    return SyncState.headers

  if ctx.hdrCache.state == ready:
    return headersFinish

  headersCancel

func headersCancelNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                     # wait for peers to sync in `poolMode`
    return headersCancel
  idle                                 # will continue hibernating

proc headersFinishNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                     # wait for peers to sync in `poolMode`
    return headersFinish

  if ctx.hdrCache.state == ready:
    if ctx.commitCollectHeaders info:  # commit downloading headers
      ctx.setupProcessingBlocks info   # initialise blocks processing
      return SyncState.blocks          # transition to blocks processing

  idle                                 # will continue hibernating

proc blocksNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if not ctx.pool.seenData and         # checks for cul-de-sac syncing
     nFetchBodiesFailedInitialPeersThreshold < ctx.pool.failedPeers.len:
    debug info & ": too many failed block peers",
      failedPeers=ctx.pool.failedPeers.len,
      limit=nFetchBodiesFailedInitialPeersThreshold
    return blocksCancel

  if ctx.subState.cancelRequest:
    return blocksCancel

  if ctx.subState.headNum <= ctx.subState.topNum:
    return blocksFinish

  SyncState.blocks

func blocksCancelNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                     # wait for peers to sync in `poolMode`
    return blocksCancel
  idle                                 # will continue hibernating

func blocksFinishNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                     # wait for peers to sync in `poolMode`
    return blocksCancel
  idle                                 # will continue hibernating

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateSyncState*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update internal state when needed
  ##
  # State machine
  # ::
  #     idle <---------------+---+---+---.
  #      |                   ^   ^   ^   |
  #      v                   |   |   |   |
  #     headers -> headersCancel |   |   |
  #      |                       |   |   |
  #      v                       |   |   |
  #     headersFinish -----------'   |   |
  #      |                           |   |
  #      v                           |   |
  #     blocks -> blocksCancel ------'   |
  #      |                               |
  #      v                               |
  #     blocksFinish --------------------'
  #
  let newState =
    case ctx.pool.syncState:
    of idle:
      ctx.idleNext info

    of SyncState.headers:
      ctx.headersNext info

    of headersCancel:
      ctx.headersCancelNext info

    of headersFinish:
      ctx.headersFinishNext info

    of SyncState.blocks:
      ctx.blocksNext info

    of blocksCancel:
      ctx.blocksCancelNext info

    of blocksFinish:
      ctx.blocksFinishNext info

  if ctx.pool.syncState == newState:
    return

  let prevState = ctx.pool.syncState
  ctx.pool.syncState = newState
  ctx.subState.stateSince = Moment.now()

  case newState:
  of idle:
    info "State changed", prevState, newState,
      base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
      nSyncPeers=ctx.nSyncPeers()

  of SyncState.headers, SyncState.blocks:
    ctx.pool.lastSyncUpdLog = Moment.now() # reset logging control
    info "State changed", prevState, newState,
      base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
      target=ctx.subState.headNum, targetHash=ctx.subState.headHash.short

  else:
    # Most states require synchronisation via `poolMode`
    ctx.poolMode = true
    info "State change, waiting for sync", prevState, newState,
      nSyncPeers=ctx.nSyncPeers()

  # Final sync scrum layout reached or inconsistent/impossible state
  if newState == idle:
    ctx.handler.suspend(ctx)


proc updateLastBlockImported*(ctx: BeaconCtxRef; bn: BlockNumber) =
  ctx.subState.topNum = bn
  metrics.set(nec_sync_last_block_imported, bn.int64)

# ------------------------------------------------------------------------------
# Public functions, call-back handlers
# ------------------------------------------------------------------------------

proc updateActivateCB*(ctx: BeaconCtxRef) =
  ## If in hibernate mode, accept a cache session and activate syncer
  ##
  if ctx.hibernate and                          # only in idle mode
     ctx.pool.minInitBuddies <= ctx.nSyncPeers() and
     ctx.pool.initTarget.isNone():              # otherwise manual setup
    let (b, t) = (ctx.chain.baseNumber, ctx.hdrCache.head.number)

    # Exclude the case of a single header chain which would be `T` only
    if b+1 < t:
      ctx.pool.minInitBuddies = 0               # reset
      ctx.pool.syncState = SyncState.headers    # state transition
      ctx.subState.stateSince = Moment.now()
      ctx.hibernate = false                     # wake up

      # Update range
      ctx.headersUnprocSet(b+1, t-1)
      ctx.subState.headNum = t
      ctx.subState.headHash = ctx.hdrCache.headHash

      # Update metrics
      ctx.pool.syncEta.lastUpdate = ctx.subState.stateSince
      metrics.set(nec_sync_head, ctx.subState.headNum.int64)

      info "Activating syncer", base=b, head=ctx.chain.latestNumber,
        target=t, targetHash=ctx.subState.headHash.short,
        nSyncPeers=ctx.nSyncPeers()
      return

  if 0 < ctx.pool.minInitBuddies:
    trace "Syncer activation rejected", base=ctx.chain.baseNumber,
      head=ctx.chain.latestNumber, target=ctx.hdrCache.head.number,
      initTarget=(if ctx.pool.initTarget.isNone(): "n/a"
                  else: ctx.pool.initTarget.get.hash.short),
      nSyncPeersMin=ctx.pool.minInitBuddies, nSyncPeers=ctx.nSyncPeers()
  else:
    trace "Syncer activation rejected", base=ctx.chain.baseNumber,
      head=ctx.chain.latestNumber, target=ctx.hdrCache.head.number,
      initTarget=ctx.pool.initTarget.isSome(), nSyncPeers=ctx.nSyncPeers()

  # Failed somewhere on the way
  ctx.hdrCache.clear()


proc updateSuspendCB*(ctx: BeaconCtxRef) =
  ## Clean up sync target buckets, stop syncer activity, and and get ready
  ## for a new sync request from the `CL`.
  ##
  ctx.hdrCache.clear()

  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false

  ctx.hibernate = true

  # Update metrics
  ctx.pool.syncEta.lastUpdate = Moment.now()
  metrics.set(nec_sync_last_block_imported, 0)
  metrics.set(nec_sync_head, 0)

  info "Suspending syncer", base=ctx.chain.baseNumber,
    head=ctx.chain.latestNumber, nSyncPeers=ctx.nSyncPeers()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

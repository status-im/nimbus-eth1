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

type ResetLingerError* = enum
  NotApplicable = 0
  DownloadCancelled                                 # retry when finished
  AboutFinishing                                    # retry when finished

# ------------------------------------------------------------------------------
# Private functions, state handler helpers
# ------------------------------------------------------------------------------

proc updateSuspendSyncer(ctx: BeaconCtxRef) =
  ## Clean up sync target buckets, stop syncer activity, and and get ready
  ## for awaiting a new request from the `CL`.
  ##
  ctx.hdrCache.clear()
  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false
  ctx.subState.cancelRequest.reset

  ctx.hibernate = true

  # Update metrics
  ctx.pool.syncEta.lastUpdate = Moment.now()
  metrics.set(nec_sync_last_block_imported, 0)
  metrics.set(nec_sync_head, 0)

  info "Suspending syncer", base=ctx.chain.baseNumber,
    head=ctx.chain.latestNumber, nSyncPeers=ctx.nSyncPeers()

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
  if ctx.poolMode:                                  # wait for peers to sync
    return headersCancel

  if ctx.pool.stopBase.isSome():                    # single run mode stop?
    return SyncState.linger                         # stay until further notice

  idle                                              # will continue hibernating

proc headersFinishNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                                  # wait for peers to sync
    return headersFinish

  if ctx.hdrCache.state == ready and
     ctx.commitCollectHeaders(info):                # commit downloading headers

    if ctx.pool.stopBase.isSome():                  # single run mode stop?
      return SyncState.linger                       # stay until further notice

    ctx.setupProcessingBlocks info                  # init blocks processing
    return SyncState.blocks                         # to blocks processing

  idle                                              # will continue hibernating

proc lingerNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  ctx.updateEtaHeadersDone()                        # update metrics

  if not ctx.pool.stopNotifier.isNil:               # notify success/failure
    ctx.pool.stopNotifier(ctx.hdrCache.state == locked)
    ctx.pool.stopNotifier = BeaconNotifier(nil)     # run only once

  if ctx.subState.cancelRequest:                    # req by `stopNotifier()`
    return SyncState.idle                           # .. via `resetSingleRun()`

  SyncState.linger

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
  if ctx.poolMode:                                  # wait for peers to sync
    return blocksCancel
  idle                                              # will continue hibernating

func blocksFinishNext(ctx: BeaconCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                                  # wait for peers to sync
    return blocksCancel
  idle                                              # will continue hibernating

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc singleRunStart*(ctx: BeaconCtxRef): Opt[void] =
  if ctx.pool.syncState == idle:
    # The header cache notifier event is triggered once, and then it blocks
    # (aka edge trigger event.) If there was one while in stand-by mode, the
    # event has been irretrievably missed. So the header cache needs to be
    # cleared.
    ctx.hdrCache.clear()
    return ok()
  err()

proc resetSingleRun*(ctx: BeaconCtxRef): Result[void,ResetLingerError] =
  ## Reset state machine in single run mode to `idle` if possible, or request
  ## cancellation of the current download. In the latter case, This function
  ## has to be called again. If the system could be set to `idle` the function
  ## returns `true`, otherwise `false`.
  ##
  if ctx.pool.stopBase.isSome():
    case ctx.pool.syncState:
    of idle:
      return ok()
    of SyncState.headers:
      ctx.subState.cancelRequest = true
      return err(DownloadCancelled)
    of headersCancel:
      return err(DownloadCancelled)
    of headersFinish:
      return err(AboutFinishing)
    of linger:
      ctx.subState.cancelRequest = true
      return ok()
    else:
      discard
  err(NotApplicable)

proc updateSyncState*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update internal state when needed
  ##
  # State machine
  # ::
  #     idle <--------------------------.
  #      |                              |
  #      v                              |
  #     headers ----> headersCancel --> +
  #      |                 |            |
  #      v                 v            |
  #     headersFinish -> linger ------> +
  #      |                              |
  #      v                              |
  #     blocks -> blocksCancel -------> +
  #      |                              |
  #      v                              |
  #     blocksFinish -------------------'
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

    of linger:
      ctx.lingerNext info

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

  of SyncState.linger:
    info "State change, waiting for reset", prevState, newState,
      nSyncPeers=ctx.nSyncPeers()

  of headersCancel, headersFinish, blocksCancel, blocksFinish:
    # These states require synchronisation via `poolMode`
    ctx.poolMode = true                             # might be set already
    info "State change, waiting for sync", prevState, newState,
      nSyncPeers=ctx.nSyncPeers()

  # Final sync scrum layout reached or inconsistent/impossible state
  if newState == idle:
    ctx.updateSuspendSyncer()


proc updateLastBlockImported*(ctx: BeaconCtxRef; bn: BlockNumber) =
  ctx.subState.topNum = bn
  metrics.set(nec_sync_last_block_imported, bn.int64)

# ------------------------------------------------------------------------------
# Public functions, call-back handlers
# ------------------------------------------------------------------------------

proc updateActivateSyncer*(ctx: BeaconCtxRef) =
  ## If in hibernate mode, accept a cache session and activate syncer
  ##
  if ctx.pool.standByMode:                          # waiting for clear
    return

  if ctx.hibernate and                              # only in idle mode
     ctx.pool.minInitBuddies <= ctx.nSyncPeers() and
     ctx.pool.initTarget.isNone():                  # otherwise manual setup

    # Initialise header chain
    let (b, t) =
      if ctx.pool.stopBase.isNone():                # standard mode
        (ctx.chain.baseNumber, ctx.hdrCache.head.number)
      else:
        let stopBase = ctx.pool.stopBase.unsafeGet
        if not ctx.hdrCache.updateBlindStop(stopBase):
          trace "Syncer single run rejected", stopBase=stopBase.number,
            head=ctx.chain.latestNumber
          ctx.hdrCache.clear()
          return
        (stopBase.number, ctx.hdrCache.head.number)

    # Exclude the case of a single header chain which would be `T` only
    if b+1 < t:
      ctx.pool.minInitBuddies = 0                   # reset
      ctx.pool.syncState = SyncState.headers        # state transition
      ctx.subState.stateSince = Moment.now()
      ctx.hibernate = false                         # wake up

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
      manualTarget=(if ctx.pool.initTarget.isNone(): "n/a"
                    else: ctx.pool.initTarget.get.hash.short),
      nSyncPeersMin=ctx.pool.minInitBuddies, nSyncPeers=ctx.nSyncPeers()
  else:
    trace "Syncer activation rejected", base=ctx.chain.baseNumber,
      head=ctx.chain.latestNumber, target=ctx.hdrCache.head.number,
      manualTarget=ctx.pool.initTarget.isSome(), nSyncPeers=ctx.nSyncPeers()

  # Failed somewhere on the way
  ctx.hdrCache.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

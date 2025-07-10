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
  pkg/[chronicles, chronos],
  pkg/eth/common,
  ../worker_desc,
  ./[blocks, headers]

logScope:
  topics = "beacon sync"

import
  ./blocks/[blocks_debug, blocks_queue],
  ./headers/[headers_debug, headers_queue]

# ------------------------------------------------------------------------------
# Private functions, state handler helpers
# ------------------------------------------------------------------------------

proc commitCollectHeaders(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Link header chain into `FC` module. Gets ready for block import.
  ##
  # This function does the job linking into `FC` module proper
  ctx.hdrCache.commit().isOkOr:
    trace info & ": cannot finalise header chain",
      B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr,
      D=ctx.hdrCache.antecedent.bnStr, H=ctx.hdrCache.head.bnStr,
      `error`=error
    return false

  true

proc setupProcessingBlocks(ctx: BeaconCtxRef; info: static[string]) =
  ## Prepare for blocks processing
  ##
  if not ctx.blocksUnprocIsEmpty() or
     not ctx.blocksStagedQueueIsEmpty() or
     not ctx.headersUnprocIsEmpty() or
     not ctx.headersStagedQueueIsEmpty() or
     ctx.subState.top != 0 or
     ctx.subState.head != 0 or
     ctx.subState.cancelRequest:
    error "updateSuspendCB: Oops", blk=ctx.blk.bnStr, hdr=ctx.hdr.bnStr,
      syncState=($ctx.syncState)
  doAssert ctx.blocksUnprocIsEmpty()
  doAssert ctx.blocksStagedQueueIsEmpty()
  doAssert ctx.headersUnprocIsEmpty()
  doAssert ctx.headersStagedQueueIsEmpty()
  doAssert ctx.subState.top == 0
  doAssert ctx.subState.head == 0
  doAssert not ctx.subState.cancelRequest

  #ctx.headersUnprocClear()
  #ctx.blocksUnprocClear()
  #ctx.headersStagedQueueClear()
  #ctx.blocksStagedQueueClear()

  # Reset for useles block download detection (to avoid deadlock)
  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false

  # Re-initialise sub-state variables
  ctx.subState.top = ctx.hdrCache.antecedent.number - 1
  ctx.subState.head = ctx.hdrCache.head.number
  ctx.subState.headHash = ctx.hdrCache.headHash

  # Update list of block numbers to process
  ctx.blocksUnprocSet(ctx.subState.top + 1, ctx.subState.head)

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

  if ctx.subState.head <= ctx.subState.top:
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
    case ctx.pool.lastState:
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

  if ctx.pool.lastState == newState:
    return

  let prevState = ctx.pool.lastState
  ctx.pool.lastState = newState

  case newState:
  of idle:
    info "State changed", prevState, newState,
      base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
      nSyncPeers=ctx.pool.nBuddies

  of SyncState.headers, SyncState.blocks:
    info "State changed", prevState, newState,
      base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
      target=ctx.subState.head.bnStr, targetHash=ctx.subState.headHash.short

  else:
    # Most states require synchronisation via `poolMode`
    ctx.poolMode = true
    info "State change, waiting for sync", prevState, newState,
      nSyncPeers=ctx.pool.nBuddies

  # Final sync scrum layout reached or inconsistent/impossible state
  if newState == idle:
    ctx.handler.suspend(ctx)

# ------------------------------------------------------------------------------
# Public functions, call-back handler ready
# ------------------------------------------------------------------------------

proc updateActivateCB*(ctx: BeaconCtxRef) =
  ## If in hibernate mode, accept a cache session and activate syncer
  ##
  if ctx.hibernate:
    let (b, t) = (ctx.chain.baseNumber, ctx.hdrCache.head.number)

    # Exclude the case of a single header chain which would be `T` only
    if b+1 < t:
      ctx.pool.lastState = SyncState.headers    # state transition
      ctx.hibernate = false                     # wake up

      # Update range
      ctx.headersUnprocSet(b+1, t-1)
      ctx.subState.head = t
      ctx.subState.headHash = ctx.hdrCache.headHash

      info "Activating syncer", base=b.bnStr, head=ctx.chain.latestNumber.bnStr,
        target=t.bnStr, targetHash=ctx.subState.headHash.short,
        nSyncPeers=ctx.pool.nBuddies
      return

    # Failed somewhere on the way
    ctx.hdrCache.clear()

  debug "Syncer activation rejected", base=ctx.chain.baseNumber.bnStr,
    head=ctx.chain.latestNumber.bnStr, state=ctx.hdrCache.state


proc updateSuspendCB*(ctx: BeaconCtxRef) =
  ## Clean up sync target buckets, stop syncer activity, and and get ready
  ## for a new sync request from the `CL`.
  ##
  ctx.hdrCache.clear()

  ctx.pool.clReq.reset
  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false

  ctx.hibernate = true

  info "Suspending syncer", base=ctx.chain.baseNumber.bnStr,
    head=ctx.chain.latestNumber.bnStr, nSyncPeers=ctx.pool.nBuddies

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

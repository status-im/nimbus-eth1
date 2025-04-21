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
  ./blocks_staged/staged_queue,
  ./headers_staged/staged_queue,
  ./[blocks_unproc, headers_unproc, helpers]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func statePair(a, b: SyncLayoutState): int =
  ## Represent state pair `(a,b)` as a single entity
  a.ord * 100 + b.ord

func statePair(a: SyncLayoutState): int =
  a.statePair a

# ------------------------------------------------------------------------------
# Private functions, state handlers
# ------------------------------------------------------------------------------

proc startHibernating(ctx: BeaconCtxRef; info: static[string]) =
  ## Clean up sync scrum target buckets and await a new request from `CL`.
  ##
  ctx.pool.lastState.reset
  ctx.pool.clReq.reset
  ctx.headersUnprocClear()
  ctx.blocksUnprocClear()
  ctx.headersStagedQueueClear()
  ctx.blocksStagedQueueClear()

  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false

  ctx.hdrCache.clear()

  ctx.hibernate = true

  info "Suspending syncer", base=ctx.chain.baseNumber.bnStr,
    head=ctx.chain.latestNumber.bnStr


proc commitCollectHeaders(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Link header chain into `FC` module. Gets ready for block import.
  let
    b = ctx.chain.baseNumber()
    l = ctx.chain.latestNumber()
    h = ctx.head.number

  # This function does the job linking into `FC` module proper
  ctx.hdrCache.commit().isOkOr:
    trace info & ": cannot commit header chain", B=b.bnStr, L=l.bnStr,
      D=ctx.dangling.bnStr, H=h.bnStr, `error`=error
    return false

  trace info & ": header chain linked into FC", B=b.bnStr, L=l.bnStr,
    D=ctx.dangling.bnStr, H=h.bnStr

  true


proc setupFinishedHeaders(ctx: BeaconCtxRef; info: static[string]) =
  ## Trivial state transition handler
  ctx.headersUnprocClear()
  ctx.headersStagedQueueClear()
  ctx.pool.lastState = finishedHeaders

proc setupCancelHeaders(ctx: BeaconCtxRef; info: static[string]) =
  ## Trivial state transition handler
  ctx.pool.lastState = cancelHeaders
  ctx.poolMode = true # reorg, clear header queues

proc setupCancelBlocks(ctx: BeaconCtxRef; info: static[string]) =
  ## Trivial state transition handler
  ctx.pool.lastState = cancelBlocks
  ctx.poolMode = true # reorg, clear block queues


proc setupProcessingBlocks(ctx: BeaconCtxRef; info: static[string]) =
  doAssert ctx.blocksUnprocIsEmpty()
  doAssert ctx.blocksStagedQueueIsEmpty()

  # Reset for useles block download detection (to avoid deadlock)
  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false

  # Prepare for blocks processing
  let
    d = ctx.dangling.number
    h = ctx.head().number

  # Update list of block numbers to process
  ctx.blocksUnprocSet(d, h)

  # State transition
  ctx.pool.lastState = processingBlocks

  trace info & ": collecting block bodies", iv=BnRange.new(d+1, h)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateSyncState*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update internal state when needed

  # Calculate the pair `(prevState,thisState)` in order to check for a state
  # change.
  let prevState = ctx.pool.lastState     # previous state
  var thisState =                        # figure out current state
    if prevState in {cancelHeaders,cancelBlocks}:
      prevState                          # no need to change state here
    else:
      case ctx.hdrCache.state:           # currently observed state, the std way
      of collecting: collectingHeaders
      of ready:      finishedHeaders
      of locked:     processingBlocks
      else:          idleSyncState

  # Handle same state cases first (i.e. no state change.) Depending on the
  # context, a new state might be forced so that there will be a state change.
  case statePair(prevState, thisState)
  of statePair(collectingHeaders):
    if ctx.pool.seenData or              # checks for cul-de-sac syncing
       ctx.pool.failedPeers.len <= fetchHeadersFailedInitialFailPeersHwm:
      return
    debug info & ": too many failed header peers",
      failedPeers=ctx.pool.failedPeers.len,
      limit=fetchHeadersFailedInitialFailPeersHwm
    thisState = cancelHeaders
    # proceed

  of statePair(cancelHeaders):           # was not assigned by `syncState()`
    if not ctx.headersBorrowedIsEmpty(): # wait for peers to reorg in `poolMode`
      return
    thisState = idleSyncState            # will continue hibernating
    # proceed

  of statePair(finishedHeaders):
    if ctx.commitCollectHeaders(info):   # commit downloading headers
      thisState = processingBlocks
    else:
      thisState = idleSyncState          # will continue hibernating
    # proceed

  of statePair(processingBlocks):
    if not ctx.pool.seenData and         # checks for cul-de-sac syncing
       fetchBodiesFailedInitialFailPeersHwm < ctx.pool.failedPeers.len:
      debug info & ": too many failed block peers",
        failedPeers=ctx.pool.failedPeers.len,
        limit=fetchBodiesFailedInitialFailPeersHwm
      thisState = cancelBlocks
      # proceed
    elif ctx.blocksStagedQueueIsEmpty() and
         ctx.blocksUnprocIsEmpty():
      thisState = idleSyncState          # will continue hibernating
      # proceed
    else:
      return

  of statePair(cancelBlocks):
    if not ctx.blocksBorrowedIsEmpty():  # wait for peers to reorg in `poolMode`
      return
    thisState = idleSyncState            # will continue hibernating
    # proceed

  elif prevState == thisState:
    return

  # Process state transition
  case statePair(prevState, thisState)
  of statePair(collectingHeaders, cancelHeaders):
    ctx.setupCancelHeaders info          # cancel header download
    thisState = ctx.pool.lastState       # assign result from state handler

  of statePair(finishedHeaders, processingBlocks):
    ctx.setupProcessingBlocks info       # start downloading block bodies
    thisState = ctx.pool.lastState       # assign result from state handler

  of statePair(processingBlocks, cancelBlocks):
    ctx.setupCancelBlocks info           # cancel blocks download
    thisState = ctx.pool.lastState       # assign result from state handler

  of statePair(collectingHeaders, finishedHeaders):
    ctx.setupFinishedHeaders info        # call state handler
    thisState = ctx.pool.lastState       # assign result from state handler

  else:
    # Use transition as is (no handler)
    discard

  info "Sync state changed", prevState, thisState,
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.head.bnStr

  # Final sync scrum layout reached or inconsistent/impossible state
  if thisState == idleSyncState:
    ctx.startHibernating info


proc updateFromHibernateSetTarget*(
    ctx: BeaconCtxRef;
    fin: Header;
    info: static[string];
      ) =
  ## If in hibernate mode, accept a cache session and activate syncer
  ##
  if ctx.hibernate:
    # Clear cul-de-sac prevention registry. This applies to both, successful
    # access handshake or error.
    ctx.pool.failedPeers.clear()

    if ctx.hdrCache.accept(fin):
      let (b, t) = (ctx.chain.baseNumber, ctx.head.number)

      # Exclude the case of a single header chain which would be `T` only
      if b+1 < t:
        ctx.pool.lastState = collectingHeaders    # state transition
        ctx.hibernate = false                     # wake up

        # Update range
        ctx.headersUnprocSet(b+1, t-1)

        info "Activating syncer", base=b.bnStr,
          head=ctx.chain.latestNumber.bnStr, fin=fin.bnStr, target=t.bnStr
        return

    # Failed somewhere on the way
    ctx.hdrCache.clear()

  debug info & ": activation rejected", base=ctx.chain.baseNumber.bnStr,
    head=ctx.chain.latestNumber.bnStr, state=ctx.hdrCache.state


proc updateFailedPeersFromResolvingFinalizer*(
    ctx: BeaconCtxRef;
    info: static[string];
      ) =
  ## This function resets the finalised hash resolver if there are too many
  ## sync peer download errors. This prevents from a potential deadlock if
  ## the syncer is notified with bogus `(finaliser,sync-head)` data.
  ##
  if ctx.hibernate:
    if fetchFinalisedHashResolverFailedPeersHwm < ctx.pool.failedPeers.len:
      info "Abandoned resolving hash (try next)",
        finHash=ctx.pool.finRequest.short, failedPeers=ctx.pool.failedPeers.len
      ctx.hdrCache.clear()
      ctx.pool.failedPeers.clear()
      ctx.pool.finRequest = zeroHash32


proc updateAsyncTasks*(
    ctx: BeaconCtxRef;
      ): Future[Opt[void]] {.async: (raises: []).} =
  ## Allow task switch by issuing a short sleep request. The `due` argument
  ## allows to maintain a minimum time gap when invoking this function.
  ##
  let start = Moment.now()
  if ctx.pool.nextAsyncNanoSleep < start:

    try: await sleepAsync asyncThreadSwitchTimeSlot
    except CancelledError: discard

    if ctx.daemon:
      ctx.pool.nextAsyncNanoSleep = Moment.now() + asyncThreadSwitchGap
      return ok()
    # Shutdown?
    return err()

  return ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

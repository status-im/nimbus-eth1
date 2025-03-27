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

# ------------

proc syncState(ctx: BeaconCtxRef; info: static[string]): SyncLayoutState =
  ## Calculate `SyncLayoutState` from the download context
  ##
  let
    b = ctx.chain.baseNumber()
    l = ctx.chain.latestNumber()
    c = ctx.layout.coupler
    d = ctx.layout.dangling
    h = ctx.layout.head

  # See clause *(8)* in `README.md`:
  # ::
  #     0               H    L
  #     o---------------o----o
  #     | <--- imported ---> |
  #
  # where `H << L` with `L` is the `latest` (aka cursor) parameter from
  # `FC` the logic will be updated to (see clause *(9)* in `README.md`):
  #
  if h <= c or h <= l:                 # empty interval `(C,H]` or nothing to do
    return idleSyncState

  # See clauses *(9)* and *(10)* in `README.md`:
  # ::
  #   0               B
  #   o---------------o----o
  #   | <--- imported ---> |
  #                C                     D                H
  #                o---------------------o----------------o
  #                | <-- unprocessed --> | <-- linked --> |
  #
  # where *B* is the **base** entity of the `FC` module and `C` is sort of
  # a placehoder with block number equal to *B* at some earlier time (the
  # value *B* increases over time.)
  #
  # It is already known that `C < H` (see first check)
  #
  if c <= b:                           # check for `C <= B` as sketched above

    # Case `C < D-1` => not ready yet
    if c + 1 < d:
      return collectingHeaders

    # Case `C == D-1` => just finished the download
    if c + 1 == d:
      return finishedHeaders

    # Case `C == D` => see below for general case

  # Case `C == D` => set to import blocks (see *(10)* in `README.md`):
  # ::
  #   0                    L
  #   o--------------------o
  #   | <--- imported ---> |
  #                     D
  #                     C                                H
  #                     o--------------------------------o
  #                     | <-- blocks to be completed --> |
  #
  # It is known already (see first check) that `L <`H`
  #
  if c == d:
    return processingBlocks

  # Case `B < C` oops:
  # ::
  #     0               B
  #     o---------------o----o
  #     | <--- imported ---> |
  #                        C                     D                H
  #                        o---------------------o----------------o
  #                        | <-- unprocessed --> | <-- linked --> |
  #
  debug info & ": inconsistent state",
    B=(if b == c: "C" else: b.bnStr),
    C=(if c == l: "L" else: c.bnStr),
    L=(if l == d: "D" else: l.bnStr),
    D=(if d == h: "H" else: d.bnStr),
    H=h.bnStr

  idleSyncState


proc linkIntoFc(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Link `(C,H]` into the `FC` logic. If successful, `true` is returned.
  ## Otherwise the chain `(C,H]` must be discarded.
  ##
  ## Condider the following layout (see clause *(10)* in `README.md`):
  ## ::
  ##   0             B  Y    L
  ##   o-------------o--o----o
  ##   | <--- imported ----> |
  ##                C    Z                                H
  ##                o----o--------------------------------o
  ##                | <------------- linked ------------> |
  ##
  ## for some `Y` in `[B,L]` and `Z` in `(C,H]` where `Y<-Z` with `L` the
  ## `latest` and `B` the `base` entity of the `FC` logic.
  ##
  ## If there are such `Y <- Z`, then update the sync state to (see chause
  ## *(11)* in `README.md`):
  ## ::
  ##   0                Y
  ##   o----------------o----o
  ##   | <--- imported ----> |
  ##                   D
  ##                   C Z                              H
  ##                   o-o------------------------------o
  ##                   | <-- blocks to be completed --> |
  ##
  ## where `C==Y`, `(C,H]==[Z,H]`, `C<-Z`
  ##
  ## Otherwise, if *Z* does not exists then reset to idle state.
  ##
  let
    b = ctx.chain.baseNumber()
    l = ctx.chain.latestNumber()
    c = ctx.layout.coupler
    h = ctx.layout.head

  if l < h:
    # Try to find a parent in the `FC` data domain. For practical reasons the
    # loop does not go further back than the base `B`. Blocks below/older than
    # that will not be handled by the `FC`.
    for bn in l.countdown(max(b,c)):

      # Get child header `Z` from header queue
      let zHdr = ctx.hdrCache.fcHeaderGet(bn+1).expect "header"

      # Check whether `Z` links into the `FC` module
      let yHdr = ctx.chain.headerByHash(zHdr.parentHash).valueOr: continue

      ctx.layout.coupler = bn                                  # parent of `Z`
      ctx.layout.dangling = bn                                 # .. ditto

      ctx.hdrCache.fcHeaderPutCommit(bn+1).isOkOr:
        trace info & ": cannot commit header chain", B=b.bnStr, L=l.bnStr,
          C=c.bnStr, H=h.bnStr, `error`=error
        return false

      trace info & ": header chain linked into FC", B=b.bnStr,
        C=(if bn==l: "L" else: bn.bnStr), L=l.bnStr, H=h.bnStr

      return true

  trace info & ": cannot link into FC", B=b.bnStr, L=l.bnStr,
    C=c.bnStr, H=h.bnStr
  false

# ------------------------------------------------------------------------------
# Private functions, state handlers
# ------------------------------------------------------------------------------

proc startHibernating(ctx: BeaconCtxRef; info: static[string]) =
  ## Clean up sync scrum target buckets and await a new request from `CL`.
  ##
  ctx.sst.reset                               # => clRequest.reset, layout.reset
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


proc setupCollectingHeaders(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Set up sync scrum target header (see clause *(9)* in `README.md`) by
  ## modifying layout to:
  ## ::
  ##   0            B
  ##   o------------o-------o
  ##   | <--- imported ---> |                           D
  ##                C                                   H
  ##                o-----------------------------------o
  ##                | <--------- unprocessed ---------> |
  ##
  ## where *B* is the **base** entity of the `FC` module and `C ~ B`. The
  ## parameter `H` is set to the new sync request `T` from the `CL`.
  ##
  let
    c = ctx.chain.baseNumber()
    t = ctx.hdrCache.fcHeaderHead.number

  doAssert ctx.headersUnprocIsEmpty()
  doAssert ctx.headersStagedQueueIsEmpty()
  doAssert ctx.blocksUnprocIsEmpty()
  doAssert ctx.blocksStagedQueueIsEmpty()
  doAssert ctx.pool.failedPeers.len == 0
  doAssert ctx.pool.seenData == false

  # This condition is typically guaranteed by the `FC` sub-module
  if c+1 < t:                                 # header chain interval is `(C,T]`
    ctx.sst.layout = SyncStateLayout(
      coupler:   c,
      dangling:  t,
      head:      t,
      lastState: collectingHeaders)           # state transition

    # Update range
    ctx.headersUnprocSet(c+1, t-1)

    trace info & ": new sync scrum target", C=c.bnStr, D="H", H="T", T=t.bnStr
    return true


proc setupFinishedHeaders(ctx: BeaconCtxRef; info: static[string]) =
  ## Trivial state transition handler
  ctx.layout.lastState = finishedHeaders

proc setupCancelHeaders(ctx: BeaconCtxRef; info: static[string]) =
  ## Trivial state transition handler
  ctx.layout.lastState = cancelHeaders
  ctx.poolMode = true # reorg, clear header queues

proc setupCancelBlocks(ctx: BeaconCtxRef; info: static[string]) =
  ## Trivial state transition handler
  ctx.layout.lastState = cancelBlocks
  ctx.poolMode = true # reorg, clear block queues


proc setupProcessingBlocks(ctx: BeaconCtxRef; info: static[string]) =
  doAssert ctx.headersUnprocIsEmpty()
  doAssert ctx.headersStagedQueueIsEmpty()
  doAssert ctx.blocksUnprocIsEmpty()
  doAssert ctx.blocksStagedQueueIsEmpty()

  # Reset for useles block download detection (to avoid deadlock)
  ctx.pool.failedPeers.clear()
  ctx.pool.seenData = false

  # Prepare for blocks processing
  let
    c = ctx.layout.coupler
    h = ctx.layout.head

  # Update blocks `(C,H]`
  ctx.blocksUnprocSet(c+1, h)

  # State transition
  ctx.layout.lastState = processingBlocks

  trace info & ": collecting block bodies", iv=BnRange.new(c+1, h)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateSyncState*(ctx: BeaconCtxRef; info: static[string]) =
  ## Update internal state when needed

  # Calculate the pair `(prevState,thisState)` in order to check for a state
  # change.
  let prevState = ctx.layout.lastState   # previous state
  var thisState =                        # figure out current state
    if prevState in {cancelHeaders,cancelBlocks}:
      prevState                          # no need to change state here
    else:
      ctx.syncState info                 # currently observed state, the std way

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
    if ctx.linkIntoFc(info):             # commit downloading headers
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
    thisState = ctx.layout.lastState     # assign result from state handler

  of statePair(finishedHeaders, processingBlocks):
    ctx.setupProcessingBlocks info       # start downloading block bodies
    thisState = ctx.layout.lastState     # assign result from state handler

  of statePair(processingBlocks, cancelBlocks):
    ctx.setupCancelBlocks info           # cancel blocks download
    thisState = ctx.layout.lastState     # assign result from state handler

  of statePair(collectingHeaders, finishedHeaders):
    ctx.setupFinishedHeaders info        # call state handler
    thisState = ctx.layout.lastState     # assign result from state handler

  else:
    # Use transition as is (no handler)
    discard

  info "Sync state changed", prevState, thisState,
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.layout.head.bnStr

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
    if ctx.hdrCache.accept(fin):
      if ctx.setupCollectingHeaders(info):
        ctx.hibernate = false
        info "Activating syncer", base=ctx.chain.baseNumber.bnStr,
          head=ctx.chain.latestNumber.bnStr, fin=fin.bnStr,
          target=ctx.layout.head.bnStr
        return

    # Failed somewhere on the way
    ctx.hdrCache.clear()
    debug info & ": activation rejected", base=ctx.chain.baseNumber.bnStr,
      head=ctx.chain.latestNumber.bnStr, fin=fin.bnStr


proc updateAsyncTasks*(
    ctx: BeaconCtxRef;
      ): Future[Opt[void]] {.async: (raises: []).} =
  ## Allow task switch by issuing a short sleep request. The `due` argument
  ## allows to maintain a minimum time gap when invoking this function.
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

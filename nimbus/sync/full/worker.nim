# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch and store blocks
## ======================
##
## Worker items state diagram and sketch of sync algorithm:
## ::
##   set of unprocessed | peer workers     | list of work items ready
##   block ranges       |                  | for persistent database
##   ==================================================================
##
##       +---------------------------------------------+
##       |                                             |
##       |  +---------------------------------+        |
##       |  |                                 |        |
##       V  v                                 |        |
##   <unprocessed> ---+-----> <worker-0> -----+---> <staged> ---> block chain
##                    |                       |
##                    +-----> <worker-1> -----+
##                    |                       |
##                    +-----> <worker-2> -----+
##                    :                       :
##
## A work item is created from a range of block numbers extracted from the
## `<unprocessed>` set of block ranges.
##
## A work item consists of a
## * current state `<worker-#>` or `<staged>`
## * given range of consecutive block numbers `[from..to]`
## * sequence of block headers relating to `[from..to]` (to be completed)
## * sequence of block buddies relating to `[from..to]` (to be completed)
##
## Block ranges *may* be recycled back into the `<unprocessed>` set when a
## work item is destroyed. This is supposed to be an exceptional case.
## Typically, a `<staged>` work item is added to the persistent block chain
## database and destroyed without block range recycling.
##
## Beware of `<staged>` overflow
## -----------------------------
## When the `<staged>` queue gets too long in non-backtrack/re-org mode, this
## may be caused by a gap between the least `<unprocessed>` block number and
## the least `<staged>` block number. Then a mechanism is invoked where
## `<unprocessed>` block range is updated.
##
## For backtrack/re-org the system runs in single instance mode tracing
## backvards parent hash references. So updating `<unprocessed>` block numbers
## would have no effect. In that case, the record with the largest block
## numbers are deleted from the `<staged>` list.
##

import
  std/[algorithm, hashes, options, sequtils, sets, strutils],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/[byteutils, interval_set, sorted_set],
  "../.."/[db/db_chain, utils],
  ".."/[protocol, pivot/best_pivot, sync_desc],
  ./ticker

{.push raises:[Defect].}

logScope:
  topics = "full-sync"

const
  minPeersToStartSync = ##\
    ## Wait for consensus of at least this number of peers before syncing.
    2

  maxStagedWorkItems = ##\
    ## Maximal items in the `staged` list.
    70

  stagedWorkItemsTrigger = ##\
    ## Turn on the global `poolMode` if there are more than this many items
    ## staged.
    50

type
  BlockRangeSetRef = ##\
    ## Disjunct sets of block number intervals
    IntervalSetRef[BlockNumber,UInt256]

  BlockRange = ##\
    ## Block number interval
    Interval[BlockNumber,UInt256]

  WorkItemQueue = ##\
    ## Block intervals sorted by least block number
    SortedSet[BlockNumber,WorkItemRef]

  WorkItemWalkRef = ##\
    ## Fast traversal descriptor for `WorkItemQueue`
    SortedSetWalkRef[BlockNumber,WorkItemRef]

  WorkItemRef = ref object
    ## Block worker item wrapper for downloading a block range
    blocks: BlockRange              ## Block numbers to fetch
    topHash: Option[Hash256]        ## Fetch by top hash rather than blocks
    headers: seq[BlockHeader]       ## Block headers received
    hashes: seq[Hash256]            ## Hashed from `headers[]` for convenience
    bodies: seq[BlockBody]          ## Block bodies received

  BuddyData* = object
    ## Local descriptor data extension
    pivot: BestPivotWorkerRef       ## Local pivot worker descriptor
    bestNumber: Option[BlockNumber] ## Largest block number reported

  CtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext       ## Random generator, pre-initialised
    pivot: BestPivotCtxRef          ## Global pivot descriptor
    backtrack: Option[Hash256]      ## Find reverse block after re-org
    unprocessed: BlockRangeSetRef   ## Block ranges to fetch
    staged: WorkItemQueue           ## Blocks fetched but not stored yet
    topPersistent: BlockNumber      ## Up to this block number stored OK
    ticker: TickerRef               ## Logger ticker

  FullBuddyRef* = ##\
    ## Extended worker peer descriptor
    BuddyRef[CtxData,BuddyData]

  FullCtxRef* = ##\
    ## Extended global descriptor
    CtxRef[CtxData]

let
  highBlockNumber = high(BlockNumber)
  highBlockRange = BlockRange.new(highBlockNumber,highBlockNumber)

static:
  doAssert stagedWorkItemsTrigger < maxStagedWorkItems

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(peer: Peer): Hash =
  ## Mixin `HashSet[Peer]` handler
  hash(cast[pointer](peer))

proc `+`(n: BlockNumber; delta: static[int]): BlockNumber =
  ## Syntactic sugar for expressions like `xxx.toBlockNumber + 1`
  n + delta.toBlockNumber

proc `-`(n: BlockNumber; delta: static[int]): BlockNumber =
  ## Syntactic sugar for expressions like `xxx.toBlockNumber - 1`
  n - delta.toBlockNumber

proc merge(ivSet: BlockRangeSetRef; wi: WorkItemRef): Uint256 =
  ## Syntactic sugar
  ivSet.merge(wi.blocks)

proc reduce(ivSet: BlockRangeSetRef; wi: WorkItemRef): Uint256 =
  ## Syntactic sugar
  ivSet.reduce(wi.blocks)


proc pp(n: BlockNumber): string =
  ## Dedicated pretty printer (`$` is defined elsewhere using `UInt256`)
  if n == highBlockNumber: "high" else:"#" & $n

proc `$`(iv: BlockRange): string =
  ## Needed for macro generated DSL files like `snap.nim` because the
  ## `distinct` flavour of `NodeTag` is discarded there.
  result = "[" & iv.minPt.pp
  if iv.minPt != iv.maxPt:
    result &= "," & iv.maxPt.pp
  result &= "]"

proc `$`(n: Option[BlockRange]): string =
  if n.isNone: "n/a" else: $n.get

proc `$`(n: Option[BlockNumber]): string =
  if n.isNone: "n/a" else: n.get.pp

proc `$`(brs: BlockRangeSetRef): string =
  "{" & toSeq(brs.increasing).mapIt($it).join(",") & "}"

# ------------------------------------------------------------------------------
# Private getters
# ------------------------------------------------------------------------------

proc nextUnprocessed(desc: var CtxData): Option[BlockNumber] =
  ## Pseudo getter
  let rc = desc.unprocessed.ge()
  if rc.isOK:
    result = some(rc.value.minPt)

proc nextStaged(desc: var CtxData): Option[BlockRange] =
  ## Pseudo getter
  let rc = desc.staged.ge(low(BlockNumber))
  if rc.isOK:
    result = some(rc.value.data.blocks)

# ------------------------------------------------------------------------------
# Private functions affecting all shared data
# ------------------------------------------------------------------------------

proc globalReset(ctx: FullCtxRef; backBlocks = maxHeadersFetch): bool =
  ## Globally flush `pending` and `staged` items and update `unprocessed`
  ## ranges and set the `unprocessed` back before the best block number/
  var topPersistent: BlockNumber
  try:
    let
      bestNumber = ctx.chain.getBestBlockHeader.blockNumber
      nBackBlocks = backBlocks.toBlockNumber
    # Initialise before best block number
    topPersistent =
      if nBackBlocks < bestNumber: bestNumber - nBackBlocks
      else: 0.toBlockNumber
  except CatchableError as e:
    error "Best block header problem", backBlocks, error=($e.name), msg=e.msg
    return false

  ctx.data.unprocessed.clear()
  ctx.data.staged.clear()
  ctx.data.topPersistent = topPersistent
  discard ctx.data.unprocessed.merge(topPersistent + 1, highBlockNumber)

  true

proc tickerUpdater(ctx: FullCtxRef): TickerStatsUpdater =
  result = proc: TickerStats =
    let
      stagedRange = ctx.data.nextStaged
      nextStaged = if stagedRange.isSome: some(stagedRange.get.minPt)
                   else: none(BlockNumber)
    TickerStats(
      topPersistent:   ctx.data.topPersistent,
      nextStaged:      nextStaged,
      nextUnprocessed: ctx.data.nextUnprocessed,
      nStagedQueue:    ctx.data.staged.len,
      reOrg:           ctx.data.backtrack.isSome)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template safeTransport(
    buddy: FullBuddyRef;
    info: static[string];
    code: untyped) =
  try:
    code
  except TransportError as e:
    error info & ", stop", error=($e.name), msg=e.msg
    buddy.ctrl.stopped = true

proc newWorkItem(buddy: FullBuddyRef): Result[WorkItemRef,void] =
  ## Fetch the next unprocessed block range and register it as work item.
  ##
  ## This function will grab a block range from the `unprocessed` range set,
  ## ove it and return it as a `WorkItemRef`. The returned range is registered
  ## in the `pending` list.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    rc = ctx.data.unprocessed.ge()
  if rc.isErr:
      return err() # no more data for this peer

  # Check whether there is somthing to do at all
  if buddy.data.bestNumber.isNone or
     buddy.data.bestNumber.get < rc.value.minPt:
    return err() # no more data for this peer

  # Compute interval
  let iv = BlockRange.new(
    rc.value.minPt,
    min(rc.value.maxPt,
        min(rc.value.minPt + maxHeadersFetch - 1,
            buddy.data.bestNumber.get)))

  discard ctx.data.unprocessed.reduce(iv)
  return ok(WorkItemRef(blocks: iv))


proc recycleStaged(buddy: FullBuddyRef) =
  ## Flush list of staged items and store the block ranges
  ## back to the `unprocessed` ranges set
  ##
  # using fast traversal
  let
    ctx = buddy.ctx
    walk = WorkItemWalkRef.init(ctx.data.staged)
  var
    rc = walk.first()
  while rc.isOk:
    # Store back into `unprocessed` ranges set
    discard ctx.data.unprocessed.merge(rc.value.data)
    rc = walk.next()
  # optional clean up, see comments on the destroy() directive
  walk.destroy()
  ctx.data.staged.clear()

# ------------------------------------------------------------------------------
# Private functions, worker sub-tasks
# ------------------------------------------------------------------------------

proc fetchHeaders(
    buddy: FullBuddyRef;
    wi: WorkItemRef
     ): Future[bool] {.async.} =
  ## Get the work item with the least interval and complete it. The function
  ## returns `true` if bodies were fetched and there were no inconsistencies.
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if 0 < wi.hashes.len:
    return true

  var hdrReq: BlocksRequest
  if wi.topHash.isNone:
    hdrReq = BlocksRequest(
      startBlock: HashOrNum(
        isHash:   false,
        number:   wi.blocks.minPt),
      maxResults: wi.blocks.len.truncate(uint),
      skip:       0,
      reverse:    false)
    trace trEthSendSendingGetBlockHeaders, peer,
      blocks=($wi.blocks)

  else:
    hdrReq = BlocksRequest(
      startBlock: HashOrNum(
        isHash:   true,
        hash:     wi.topHash.get),
      maxResults: maxHeadersFetch,
      skip:       0,
      reverse:    true)
    trace trEthSendSendingGetBlockHeaders & " reverse", peer,
      topHash=hdrReq.startBlock.hash, reqLen=hdrReq.maxResults

  # Fetch headers from peer
  var hdrResp: Option[blockHeadersObj]
  block:
    let reqLen = hdrReq.maxResults
    buddy.safeTransport("Error fetching block headers"):
      hdrResp = await peer.getBlockHeaders(hdrReq)
    # Beware of peer terminating the session
    if buddy.ctrl.stopped:
      return false

    if hdrResp.isNone:
      trace trEthRecvReceivedBlockHeaders, peer, reqLen, respose="n/a"
      return false

    let hdrRespLen = hdrResp.get.headers.len
    trace trEthRecvReceivedBlockHeaders, peer, reqLen, hdrRespLen

    if hdrRespLen == 0:
      buddy.ctrl.stopped = true
      return false

  # Update block range for reverse search
  if wi.topHash.isSome:
    # Headers are in reversed order
    wi.headers = hdrResp.get.headers.reversed
    wi.blocks = BlockRange.new(
      wi.headers[0].blockNumber, wi.headers[^1].blockNumber)
    discard ctx.data.unprocessed.reduce(wi)
    trace "Updated reverse header range", peer, range=($wi.blocks)

  # Verify start block number
  elif hdrResp.get.headers[0].blockNumber != wi.blocks.minPt:
    trace "Header range starts with wrong block number", peer,
      startBlock=hdrResp.get.headers[0].blockNumber,
      requestedBlock=wi.blocks.minPt
    buddy.ctrl.zombie = true
    return false

  # Import into `wi.headers`
  else:
    wi.headers.shallowCopy(hdrResp.get.headers)

  # Calculate block header hashes and verify it against parent links. If
  # necessary, cut off some offending block headers tail.
  wi.hashes.setLen(wi.headers.len)
  wi.hashes[0] = wi.headers[0].hash
  for n in 1 ..< wi.headers.len:
    if wi.headers[n-1].blockNumber + 1 != wi.headers[n].blockNumber:
      trace "Non-consecutive block numbers in header list response", peer
      buddy.ctrl.zombie = true
      return false
    if wi.hashes[n-1] != wi.headers[n].parentHash:
      # Oops, cul-de-sac after block chain re-org?
      trace "Dangling parent link in header list response. Re-org?", peer
      wi.headers.setLen(n)
      wi.hashes.setLen(n)
      break
    wi.hashes[n] = wi.headers[n].hash

  # Adjust range length if necessary
  if wi.headers[^1].blockNumber < wi.blocks.maxPt:
    let redRng = BlockRange.new(
      wi.headers[0].blockNumber, wi.headers[^1].blockNumber)
    trace "Adjusting block range", peer, range=($wi.blocks), reduced=($redRng)
    discard ctx.data.unprocessed.merge(redRng.maxPt + 1, wi.blocks.maxPt)
    wi.blocks = redRng

  return true


proc fetchBodies(buddy: FullBuddyRef; wi: WorkItemRef): Future[bool] {.async.} =
  ## Get the work item with the least interval and complete it. The function
  ## returns `true` if bodies were fetched and there were no inconsistencies.
  let peer = buddy.peer

  # Complete group of bodies
  buddy.safeTransport("Error fetching block bodies"):
    while wi.bodies.len < wi.hashes.len:
      let
        start = wi.bodies.len
        reqLen = min(wi.hashes.len - wi.bodies.len, maxBodiesFetch)
        top = start + reqLen
        hashes =  wi.hashes[start ..< top]

      trace trEthSendSendingGetBlockBodies, peer, reqLen

      # Append bodies from peer to `wi.bodies`
      block:
        let bdyResp = await peer.getBlockBodies(hashes)
        # Beware of peer terminating the session
        if buddy.ctrl.stopped:
          return false

        if bdyResp.isNone:
          trace trEthRecvReceivedBlockBodies, peer, reqLen, respose="n/a"
          buddy.ctrl.zombie = true
          return false

        let bdyRespLen = bdyResp.get.blocks.len
        trace trEthRecvReceivedBlockBodies, peer, reqLen, bdyRespLen

        if bdyRespLen == 0 or reqLen < bdyRespLen:
          buddy.ctrl.zombie = true
          return false

        wi.bodies.add bdyResp.get.blocks

    return true


proc stageItem(buddy: FullBuddyRef; wi: WorkItemRef) =
  ## Add work item to the list of staged items
  let
    ctx = buddy.ctx
    peer = buddy.peer
    rc = ctx.data.staged.insert(wi.blocks.minPt)
  if rc.isOk:
    rc.value.data = wi

    # Turn on pool mode if there are too may staged work items queued.
    # This must only be done when the added work item is not backtracking.
    if stagedWorkItemsTrigger < ctx.data.staged.len and
       ctx.data.backtrack.isNone and
       wi.topHash.isNone:
      buddy.ctx.poolMode = true

    # The list size is limited. So cut if necessary and recycle back the block
    # range of the discarded item (tough luck if the current work item is the
    # one removed from top.)
    while maxStagedWorkItems < ctx.data.staged.len:
      let topValue = ctx.data.staged.le(highBlockNumber).value
      discard ctx.data.unprocessed.merge(topValue.data)
      discard ctx.data.staged.delete(topValue.key)
    return

  # Ooops, duplicates should not exist (but anyway ...)
  let wj = block:
    let rc = ctx.data.staged.eq(wi.blocks.minPt)
    doAssert rc.isOk
    # Store `wi` and return offending entry
    let rcData = rc.value.data
    rc.value.data = wi
    rcData

  debug "Replacing dup item in staged list", peer,
    range=($wi.blocks), discarded=($wj.blocks)
  # Update `staged` list and `unprocessed` ranges
  block:
    let rc = wi.blocks - wj.blocks
    if rc.isOk:
      discard ctx.data.unprocessed.merge(rc.value)


proc processStaged(buddy: FullBuddyRef): bool =
  ## Fetch a work item from the `staged` queue an process it to be
  ## stored on the persistent block chain.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    chainDb = buddy.ctx.chain
    rc = ctx.data.staged.ge(low(BlockNumber))

  if rc.isErr:
    # No more items in the database
    return false

  let
    wi = rc.value.data
    topPersistent = ctx.data.topPersistent
    startNumber = wi.headers[0].blockNumber
    stagedRecords = ctx.data.staged.len

  # Check whether this record of blocks can be stored, at all
  if topPersistent + 1 < startNumber:
    trace "Staged work item postponed", peer, topPersistent,
      range=($wi.blocks), stagedRecords
    return false

  # Ok, store into the block chain database
  trace "Processing staged work item", peer,
    topPersistent, range=($wi.blocks)

  # remove from staged DB
  discard ctx.data.staged.delete(wi.blocks.minPt)

  try:
    if chainDb.persistBlocks(wi.headers, wi.bodies) == ValidationResult.OK:
      ctx.data.topPersistent = wi.blocks.maxPt
      return true
  except CatchableError as e:
    error "Storing persistent blocks failed", peer, range=($wi.blocks),
      error = $e.name, msg = e.msg
  except Defect as e:
    # Pass through
    raise e
  except Exception as e:
    # Notorious case where the `Chain` reference applied to
    # `persistBlocks()` has the compiler traced a possible `Exception`
    # (i.e. `ctx.chain` could be uninitialised.)
    error "Exception while storing persistent blocks", peer,
      range=($wi.blocks), error=($e.name), msg=e.msg
    raise (ref Defect)(msg: $e.name & ": " & e.msg)

  # Something went wrong. Recycle work item (needs to be re-fetched, anyway)
  let
    parentHash = wi.headers[0].parentHash
    parentHoN = HashOrNum(isHash: true, hash: parentHash)
  try:
    # Check whether hash of the first block is consistent
    var parent: BlockHeader
    if chainDb.getBlockHeader(parentHoN, parent):
      # First block parent is ok, so there might be other problems. Re-fetch
      # the blocks from another peer.
      trace "Storing persistent blocks failed", peer,
        range=($wi.blocks)
      discard ctx.data.unprocessed.merge(wi.blocks)
      buddy.ctrl.zombie = true
      return false
  except CatchableError as e:
    error "Failed to access parent blocks", peer,
      blockNumber=wi.headers[0].blockNumber.pp, error=($e.name), msg=e.msg

  # Parent block header problem, so we might be in the middle of a re-org.
  # Set single mode backtrack following the offending parent hash.
  ctx.data.backtrack = some(parentHash)
  buddy.ctrl.multiOk = false

  if wi.topHash.isNone:
    # Assuming that currently staged entries are on the wrong branch
    buddy.recycleStaged()
    notice "Starting chain re-org backtrack work item", peer,
      range=($wi.blocks)
  else:
    # Leave that block range in the staged list
    trace "Resuming chain re-org backtrack work item", peer,
      range=($wi.blocks)
    discard

  return false

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: FullCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.data.unprocessed = BlockRangeSetRef.init()
  ctx.data.staged.init()
  ctx.data.pivot = BestPivotCtxRef.init(ctx.data.rng)
  if tickerOK:
    ctx.data.ticker = TickerRef.init(ctx.tickerUpdater)
  else:
    debug "Ticker is disabled"
  return ctx.globalReset(0)

proc release*(ctx: FullCtxRef) =
  ## Global clean up
  ctx.data.pivot = nil
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stop()

proc start*(buddy: FullBuddyRef): bool =
  ## Initialise worker peer
  let ctx = buddy.ctx
  if buddy.peer.supports(protocol.eth) and
     buddy.peer.state(protocol.eth).initialized:
    if not ctx.data.ticker.isNil:
      ctx.data.ticker.startBuddy()
    buddy.data.pivot =
      BestPivotWorkerRef.init(ctx.data.pivot, buddy.ctrl, buddy.peer)
    return true

proc stop*(buddy: FullBuddyRef) =
  ## Clean up this peer
  let ctx = buddy.ctx
  buddy.ctrl.stopped = true
  #ctx.data.untrusted.add buddy.peer
  buddy.data.pivot.clear()
  if not ctx.data.ticker.isNil:
     ctx.data.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runSingle*(buddy: FullBuddyRef) {.async.} =
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

  if ctx.data.backtrack.isSome:
    trace "Single run mode, re-org backtracking", peer
    let wi = WorkItemRef(
      # This dummy interval can savely merged back without any effect
      blocks:  highBlockRange,
      # Enable backtrack
      topHash: some(ctx.data.backtrack.get))

    # Fetch headers and bodies for the current work item
    if await buddy.fetchHeaders(wi):
      if await buddy.fetchBodies(wi):
        ctx.data.backtrack = none(Hash256)
        buddy.stageItem(wi)

        # Update persistent database (may reset `multiOk`)
        buddy.ctrl.multiOk = true
        while buddy.processStaged() and not buddy.ctrl.stopped:
          # Allow thread switch as `persistBlocks()` might be slow
          await sleepAsync(10.milliseconds)
        return

    # This work item failed, nothing to do anymore.
    discard ctx.data.unprocessed.merge(wi)
    buddy.ctrl.zombie = true

  # Initialise/re-initialise this worker
  elif await buddy.data.pivot.bestPivotNegotiate(buddy.data.bestNumber):
    buddy.ctrl.multiOk = true
    # Update/activate `bestNumber` for local use
    buddy.data.bestNumber =
      some(buddy.data.pivot.bestPivotHeader.value.blockNumber)

  elif not buddy.ctrl.stopped:
    await sleepAsync(2.seconds)


proc runPool*(buddy: FullBuddyRef; last: bool) =
  ## Ocne started, the function `runPool()` is called for all worker peers in
  ## a row (as the body of an iteration.) There will be no other worker peer
  ## functions activated simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It is the responsibility of the `runPool()`
  ## instance to reset the flag `buddy.ctx.poolMode`, typically at the first
  ## peer instance.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  let ctx = buddy.ctx
  if ctx.poolMode:
    # Mind the gap, fill in if necessary
    let
      topPersistent = ctx.data.topPersistent
      covered = min(
        ctx.data.nextUnprocessed.get(highBlockNumber),
        ctx.data.nextStaged.get(highBlockRange).minPt)
    if topPersistent + 1 < covered:
      discard ctx.data.unprocessed.merge(topPersistent + 1, covered - 1)
    ctx.poolMode = false


proc runMulti*(buddy: FullBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  # Fetch work item
  let
    ctx = buddy.ctx
    rc = buddy.newWorkItem()
  if rc.isErr:
    # No way, end of capacity for this peer => re-calibrate
    buddy.ctrl.multiOk = false
    buddy.data.bestNumber = none(BlockNumber)
    return
  let wi = rc.value

  # Fetch headers and bodies for the current work item
  if await buddy.fetchHeaders(wi):
    if await buddy.fetchBodies(wi):
      buddy.stageItem(wi)

      # Update persistent database
      while buddy.processStaged() and not buddy.ctrl.stopped:
        # Allow thread switch as `persistBlocks()` might be slow
        await sleepAsync(10.milliseconds)
      return

  # This work item failed
  discard ctx.data.unprocessed.merge(wi)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

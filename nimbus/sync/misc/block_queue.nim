# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch and queue blocks
## ======================
##
## Worker items state diagram and sketch of sync algorithm:
## ::
##   unprocessed      |                   | ready for           | store into
##   block ranges     | peer workers      | persistent database | database
##   =======================================================================
##
##        +------------------------------------------+
##        |                                          |
##        |  +----------------------------+          |
##        |  |                            |          |
##        V  v                            |          |
##   <unprocessed> ---+---> <worker-0> ---+-----> <staged> -------> OUTPUT
##                    |                   |
##                    +---> <worker-1> ---+
##                    |                   |
##                    +---> <worker-2> ---+
##                    :                   :
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
{.push raises:[].}

import
  std/[algorithm, options, sequtils, strutils],
  chronicles,
  chronos,
  eth/p2p,
  stew/[byteutils, interval_set, sorted_set],
  ../../db/db_chain,
  ../../utils/utils,
  ".."/[protocol, sync_desc, types]

logScope:
  topics = "block-queue"

const
  maxStagedWorkItems = 70
    ## Maximal items in the `staged` list.

  stagedWorkItemsTrigger = 50
    ## Turn on the global `poolMode` if there are more than this many items
    ## staged.

type
  BlockQueueRC* = enum
    ## Return & error codes
    AllSmileOk
    EmptyQueue
    StagedQueueOverflow
    BlockNumberGap
    BacktrackDisabled
    FetchHeadersError
    FetchBodiesError
    NoMoreUnprocessed
    NoMorePeerBlocks

  BlockRangeSetRef = IntervalSetRef[BlockNumber,UInt256]
    ## Disjunct sets of block number intervals

  BlockRange = Interval[BlockNumber,UInt256]
    ## Block number interval

  BlockItemQueue = SortedSet[BlockNumber,BlockItemRef]
    ## Block intervals sorted by least block number

  BlockItemWalkRef = SortedSetWalkRef[BlockNumber,BlockItemRef]
    ## Fast traversal descriptor for `BlockItemQueue`

  BlockItemRef* = ref object
    ## Public block items, OUTPUT
    blocks*: BlockRange             ## Block numbers ranvge covered
    topHash*: Option[Hash256]       ## Fetched by top hash rather than block
    headers*: seq[BlockHeader]      ## Block headers received
    hashes*: seq[Hash256]           ## Hashed from `headers[]` for convenience
    bodies*: seq[BlockBody]         ## Block bodies received

  BlockQueueCtxRef* = ref object
    ## Globally shared data among `block` instances
    backtrack: Option[Hash256]      ## Find reverse block after re-org
    unprocessed: BlockRangeSetRef   ## Block ranges to fetch
    staged: BlockItemQueue          ## Blocks fetched but not stored yet
    topAccepted: BlockNumber        ## Up to this block number processed OK

  BlockQueueWorkerRef* = ref object
    ## Local descriptor data extension
    global: BlockQueueCtxRef        ## Common data
    bestNumber: Option[BlockNumber] ## Largest block number reported
    ctrl: BuddyCtrlRef              ## Control and state settings
    peer: Peer                      ## network peer

  BlockQueueStats* = object
    ## Statistics
    topAccepted*: BlockNumber
    nextUnprocessed*: Option[BlockNumber]
    nextStaged*: Option[BlockNumber]
    nStagedQueue*: int
    reOrg*: bool

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

  highBlockNumber = high(BlockNumber)
  highBlockRange = BlockRange.new(highBlockNumber,highBlockNumber)

static:
  doAssert stagedWorkItemsTrigger < maxStagedWorkItems

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `+`(n: BlockNumber; delta: static[int]): BlockNumber =
  ## Syntactic sugar for expressions like `xxx.toBlockNumber + 1`
  n + delta.toBlockNumber

proc `-`(n: BlockNumber; delta: static[int]): BlockNumber =
  ## Syntactic sugar for expressions like `xxx.toBlockNumber - 1`
  n - delta.toBlockNumber

proc merge(ivSet: BlockRangeSetRef; wi: BlockItemRef): Uint256 =
  ## Syntactic sugar
  ivSet.merge(wi.blocks)

proc reduce(ivSet: BlockRangeSetRef; wi: BlockItemRef): Uint256 =
  ## Syntactic sugar
  ivSet.reduce(wi.blocks)

# ---------------

proc `$`(iv: BlockRange): string =
  ## Needed for macro generated DSL files like `snap.nim` because the
  ## `distinct` flavour of `NodeTag` is discarded there.
  result = "[" & iv.minPt.toStr
  if iv.minPt != iv.maxPt:
    result &= "," & iv.maxPt.toStr
  result &= "]"

proc `$`(n: Option[BlockRange]): string =
  if n.isNone: "n/a" else: $n.get

proc `$`(n: Option[BlockNumber]): string =
  n.toStr

proc `$`(brs: BlockRangeSetRef): string =
  "{" & toSeq(brs.increasing).mapIt($it).join(",") & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc nextUnprocessed(ctx: BlockQueueCtxRef): Option[BlockNumber] =
  ## Pseudo getter
  let rc = ctx.unprocessed.ge()
  if rc.isOK:
    result = some(rc.value.minPt)

proc nextStaged(ctx: BlockQueueCtxRef): Option[BlockRange] =
  ## Pseudo getter
  let rc = ctx.staged.ge(low(BlockNumber))
  if rc.isOK:
    result = some(rc.value.data.blocks)

template safeTransport(
    qd: BlockQueueWorkerRef;
    info: static[string];
    code: untyped) =
  try:
    code
  except TransportError as e:
    error info & ", stop", error=($e.name), msg=e.msg
    qd.ctrl.stopped = true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc newWorkItem(qd: BlockQueueWorkerRef): Result[BlockItemRef,BlockQueueRC] =
  ## Fetch the next unprocessed block range and register it as work item.
  ##
  ## This function will grab a block range from the `unprocessed` range set,
  ## ove it and return it as a `BlockItemRef`. The returned range is registered
  ## in the `pending` list.
  let rc = qd.global.unprocessed.ge()
  if rc.isErr:
      return err(NoMoreUnprocessed) # no more data for this peer

  # Check whether there is somthing to do at all
  if qd.bestNumber.isNone or
     qd.bestNumber.unsafeGet < rc.value.minPt:
    when extraTraceMessages:
      trace "no new work item", bestNumer=qd.bestNumber.toStr, range=rc.value
    return err(NoMorePeerBlocks) # no more data for this peer

  # Compute interval
  let iv = BlockRange.new(
    rc.value.minPt,
    min(rc.value.maxPt,
        min(rc.value.minPt + maxHeadersFetch - 1, qd.bestNumber.unsafeGet)))

  discard qd.global.unprocessed.reduce(iv)
  ok(BlockItemRef(blocks: iv))


proc stageItem(
    qd: BlockQueueWorkerRef;
    wi: BlockItemRef;
      ): Result[void,BlockQueueRC] =
  ## Add work item to the list of staged items
  ##
  ## Typically, the function returns `AllSmileOk` unless there is a queue
  ## oberflow (with return code`StagedQueueOverflow`) which needs to be handled
  ## in *pool mode* by running `blockQueueGrout()`.
  var
    error = AllSmileOk
  let
    peer = qd.peer
    rc = qd.global.staged.insert(wi.blocks.minPt)
  if rc.isOk:
    rc.value.data = wi

    # Return `true` if staged queue oberflows (unless backtracking.)
    if stagedWorkItemsTrigger < qd.global.staged.len and
       qd.global.backtrack.isNone and
       wi.topHash.isNone:
      debug "Staged queue too long", peer,
        staged=qd.global.staged.len, max=stagedWorkItemsTrigger
      error = StagedQueueOverflow

    # The list size is limited. So cut if necessary and recycle back the block
    # range of the discarded item (tough luck if the current work item is the
    # one removed from top.)
    while maxStagedWorkItems < qd.global.staged.len:
      let topValue = qd.global.staged.le(highBlockNumber).value
      discard qd.global.unprocessed.merge(topValue.data)
      discard qd.global.staged.delete(topValue.key)
  else:
    # Ooops, duplicates should not exist (but anyway ...)
    let wj = block:
      let rc = qd.global.staged.eq(wi.blocks.minPt)
      doAssert rc.isOk
      # Store `wi` and return offending entry
      let rcData = rc.value.data
      rc.value.data = wi
      rcData

    # Update `staged` list and `unprocessed` ranges
    block:
      debug "Replacing dup item in staged list", peer,
        range=($wi.blocks), discarded=($wj.blocks)
      let rc = wi.blocks - wj.blocks
      if rc.isOk:
        discard qd.global.unprocessed.merge(rc.value)

  if error != AllSmileOk:
    return err(error)
  ok()

# ------------------------------------------------------------------------------
# Private functions, asynchroneous data network activity
# ------------------------------------------------------------------------------

proc fetchHeaders(
    qd: BlockQueueWorkerRef;
    wi: BlockItemRef;
      ): Future[bool]
      {.async.} =
  ## Get the work item with the least interval and complete it. The function
  ## returns `true` if bodies were fetched and there were no inconsistencies.
  if 0 < wi.hashes.len:
    return true

  let peer = qd.peer
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
    let reqLen {.used.} = hdrReq.maxResults
    qd.safeTransport("Error fetching block headers"):
      hdrResp = await peer.getBlockHeaders(hdrReq)
    # Beware of peer terminating the session
    if qd.ctrl.stopped:
      return false

    if hdrResp.isNone:
      trace trEthRecvReceivedBlockHeaders, peer, reqLen, respose="n/a"
      return false

    let hdrRespLen = hdrResp.get.headers.len
    trace trEthRecvReceivedBlockHeaders, peer, reqLen, hdrRespLen

    if hdrRespLen == 0:
      qd.ctrl.stopped = true
      return false

  # Update block range for reverse search
  if wi.topHash.isSome:
    # Headers are in reversed order
    wi.headers = hdrResp.get.headers.reversed
    wi.blocks = BlockRange.new(
      wi.headers[0].blockNumber, wi.headers[^1].blockNumber)
    discard qd.global.unprocessed.reduce(wi)
    trace "Updated reverse header range", peer, range=($wi.blocks)

  # Verify start block number
  elif hdrResp.get.headers[0].blockNumber != wi.blocks.minPt:
    trace "Header range starts with wrong block number", peer,
      startBlock=hdrResp.get.headers[0].blockNumber,
      requestedBlock=wi.blocks.minPt
    qd.ctrl.zombie = true
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
      qd.ctrl.zombie = true
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
    discard qd.global.unprocessed.merge(redRng.maxPt + 1, wi.blocks.maxPt)
    wi.blocks = redRng

  return true


proc fetchBodies(
    qd: BlockQueueWorkerRef;
    wi: BlockItemRef
      ): Future[bool]
      {.async.} =
  ## Get the work item with the least interval and complete it. The function
  ## returns `true` if bodies were fetched and there were no inconsistencies.
  let peer = qd.peer

  # Complete group of bodies
  qd.safeTransport("Error fetching block bodies"):
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
        if qd.ctrl.stopped:
          return false

        if bdyResp.isNone:
          trace trEthRecvReceivedBlockBodies, peer, reqLen, respose="n/a"
          qd.ctrl.zombie = true
          return false

        let bdyRespLen = bdyResp.get.blocks.len
        trace trEthRecvReceivedBlockBodies, peer, reqLen, bdyRespLen

        if bdyRespLen == 0 or reqLen < bdyRespLen:
          qd.ctrl.zombie = true
          return false

        wi.bodies.add bdyResp.get.blocks

    return true


# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type BlockQueueCtxRef;           ## Global data descriptor type
    firstBlockNumber = 0.toBlockNumber; ## Of first block to fetch from network
      ): T =
  ## Global constructor, shared data
  result = T(
    unprocessed: BlockRangeSetRef.init())
  result.staged.init()
  result.topAccepted = max(firstBlockNumber,1.toBlockNumber) - 1
  discard result.unprocessed.merge(result.topAccepted + 1, highBlockNumber)

proc init*(
    T: type BlockQueueWorkerRef;        ## Global data descriptor type
    ctx: BlockQueueCtxRef;              ## Global data descriptor
    ctrl: BuddyCtrlRef;                 ## Control and state settings
    peer: Peer;                         ## For fetching data from network
      ): T =
  ## Buddy/local constructor
  T(global: ctx,
    peer:   peer,
    ctrl:   ctrl)

# ------------------------------------------------------------------------------
# Public functions -- getter/setter
# ------------------------------------------------------------------------------

proc bestNumber*(qd: BlockQueueWorkerRef): Option[BlockNumber] =
  ## Getter
  qd.bestNumber

proc `bestNumber=`*(qd: BlockQueueWorkerRef; val: Option[BlockNumber]) =
  ## Setter, needs to be set to something valid so that `blockQueueWorker()`
  ## does something useful.
  qd.bestNumber = val

proc topAccepted*(qd: BlockQueueWorkerRef): BlockNumber =
  ## Getter
  qd.global.topAccepted

# ------------------------------------------------------------------------------
# Public functions -- synchronous
# ------------------------------------------------------------------------------

proc blockQueueFetchStaged*(
    qd: BlockQueueWorkerRef;
      ): Result[BlockItemRef,BlockQueueRC]=
  ## Fetch the next item from the staged block queue. This item will be removed
  ## from the staged queue and must be recycled if it cannot be processed.
  ##
  ## On error, the function returns `EmptyQueue` if the queue was empty and
  ## `BlockNumberGap` if processing this item would result in a gap between the
  ## last accepted block number and the fitsr block number of the next queue
  ## item.
  ##
  ## This gap might appear if another function processes the in-beween block
  ## in paralell or if something went wrong, see `blockQueueGrout()`, below.
  let rc = qd.global.staged.ge(low(BlockNumber))
  if rc.isErr:
    # No more items in the database
    return err(EmptyQueue)

  let
    peer {.used.} = qd.peer
    wi = rc.value.data
    topAccepted = qd.global.topAccepted
    startNumber = wi.headers[0].blockNumber

  # Check whether this record of blocks can be stored, at all
  if topAccepted + 1 < startNumber:
    trace "Staged work item postponed", peer, topAccepted,
      range=($wi.blocks), staged=qd.global.staged.len
    return err(BlockNumberGap)

  # Ok, store into the block chain database
  trace "Staged work item", peer,
    topAccepted, range=($wi.blocks)

  # Remove from staged DB
  discard qd.global.staged.delete(wi.blocks.minPt)

  ok(wi)


proc blockQueueAccept*(qd: BlockQueueWorkerRef; wi: BlockItemRef) =
  ## Mark this argument item `wi` to be the item with the topmost block number
  ## accepted. This statement comes tyipcally after the successful processing
  ## and storage of the work item fetched by `blockQueueFetchStaged()`.
  qd.global.topAccepted = wi.blocks.maxPt


proc blockQueueGrout*(qd: BlockQueueWorkerRef) =
  ## Fill the gap unprocessed and staged block numbers. If there is such a gap
  ## (which should not at all), the `blockQueueFetchStaged()` will always fail
  ## with a `true` error code because there is no next work item.
  ##
  ## To close the gap and avoid double processing, all other workers should
  ## have finished their tasks while this function is run. A way to achive that
  ## is to run this function in *pool mode* once.
  # Mind the gap, fill in if necessary
  let covered = min(
    qd.global.nextUnprocessed.get(otherwise = highBlockNumber),
    qd.global.nextStaged.get(otherwise = highBlockRange).minPt)
  if qd.global.topAccepted + 1 < covered:
    discard qd.global.unprocessed.merge(qd.global.topAccepted + 1, covered - 1)


proc blockQueueRecycle*(qd: BlockQueueWorkerRef; wi: BlockItemRef) =
  ## Put back and destroy the `wi` argument item. The covered block range needs
  ## to be re-fetched from the network. This statement is typically used instead
  ## of `blockQueueAccept()` after a failure tpo process and store the work item
  ## fetched by `blockQueueFetchStaged()`.
  discard qd.global.unprocessed.merge(wi.blocks)


proc blockQueueRecycleStaged*(qd: BlockQueueWorkerRef) =
  ## Similar to `blockQueueRecycle()`, recycle all items from the staged queue.
  # using fast traversal
  let
    walk = BlockItemWalkRef.init(qd.global.staged)
  var
    rc = walk.first()
  while rc.isOk:
    # Store back into `unprocessed` ranges set
    discard qd.global.unprocessed.merge(rc.value.data)
    rc = walk.next()
  # optional clean up, see comments on the destroy() directive
  walk.destroy()
  qd.global.staged.clear()


proc blockQueueBacktrackFrom*(qd: BlockQueueWorkerRef; wi: BlockItemRef) =
  ## Set backtrack mode starting with the blocks before the argument work
  ## item `wi`.
  qd.global.backtrack = some(wi.headers[0].parentHash)


proc blockQueueBacktrackOk*(qd: BlockQueueWorkerRef): bool =
  ## Returns `true` if the queue is in backtrack mode.
  qd.global.backtrack.isSome


proc blockQueueStats*(ctx: BlockQueueCtxRef; stats: var BlockQueueStats) =
  ## Collect global statistics
  stats.topAccepted = ctx.topAccepted
  stats.nextUnprocessed = ctx.nextUnprocessed
  stats.nStagedQueue = ctx.staged.len
  stats.reOrg = ctx.backtrack.isSome
  stats.nextStaged =
    if ctx.nextStaged.isSome: some(ctx.nextStaged.unsafeGet.minPt)
    else: none(BlockNumber)

# ------------------------------------------------------------------------------
# Public functions -- asynchronous
# ------------------------------------------------------------------------------

proc blockQueueBacktrackWorker*(
    qd: BlockQueueWorkerRef;
      ): Future[Result[void,BlockQueueRC]]
      {.async.} =
  ## This function does some backtrack processing on the queue. Backtracking
  ## is single threaded due to the fact that the next block is identified by
  ## the hash of the parent header. So this function needs to run in *single
  ## mode*.
  ##
  ## If backtracking is enabled, this function fetches the next parent work
  ## item from the network and makes it available on the staged queue to be
  ## retrieved with `blockQueueFetchStaged()`. In that case, the function
  ## succeeds and `blockQueueBacktrackOk()` will return `false`.
  ##
  ## In all other cases, the function returns an error code.
  var error = BacktrackDisabled
  if qd.global.backtrack.isSome:
    let
      peer {.used.} = qd.peer
      wi = BlockItemRef(
        # This dummy interval can savely merged back without any effect
        blocks:  highBlockRange,
        # Enable backtrack
        topHash: some(qd.global.backtrack.unsafeGet))

    # Fetch headers and bodies for the current work item
    trace "Single mode worker, re-org backtracking", peer
    if not await qd.fetchHeaders(wi):
      error = FetchHeadersError
    elif not await qd.fetchBodies(wi):
      error = FetchBodiesError
    else:
      qd.global.backtrack = none(Hash256)
      discard qd.stageItem(wi)
      return ok()

    # This work item failed, nothing to do anymore.
    discard qd.global.unprocessed.merge(wi)

  return err(error)


proc blockQueueWorker*(
    qd: BlockQueueWorkerRef;
      ): Future[Result[void,BlockQueueRC]]
      {.async.} =
  ## Normal worker function used to stage another work item be retrieved by
  ## `blockQueueFetchStaged()`. This function may run in *multi mode*. Not
  ## until retrieving work items the queue will be synchronised in a way that
  ## after the next item can be retrieved the queue will be blocked by a
  ## *gap* until the item is commited by `blockQueueAccept()`.
  ##
  ## On error, with most error codes there is not much that can be done. The
  ## one remarcable error code is `StagedQueueOverflow` which pops up if there
  ## is a gap between unprocessed and staged block numbers. One of the actions
  ## to be considered here is to run `blockQueueGrout()` in *pool mode*.
  ## Otherwise, the `StagedQueueOverflow` can be treated as a success would be.
  ##
  # Fetch work item
  let wi = block:
    let rc = qd.newWorkItem()
    if rc.isErr:
      # No way, end of capacity for this peer => re-calibrate
      qd.bestNumber = none(BlockNumber)
      return err(rc.error)
    rc.value

  # Fetch headers and bodies for the current work item
  var error = AllSmileOk
  if not await qd.fetchHeaders(wi):
    error = FetchHeadersError
  elif not await qd.fetchBodies(wi):
    error = FetchBodiesError
  else:
    return qd.stageItem(wi)

  # This work item failed
  discard qd.global.unprocessed.merge(wi)
  return err(error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

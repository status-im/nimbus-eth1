# nim-eth
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
## When the `<staged>` queue gets too long ini non-backtrack/re-org mode, this
## can theoretically happen if there is a gap between the least `<unprocessed>`
## block number and the least `<staged>` block number. Then a mechanism is
## invoked where `<unprocessed>` block range is updated.
##
## For backtrack/re-org the system runs in single instance mode following back
## parent hash references. So updating `<unprocessed>` block numbers would have
## no effect. In that case, the record with the largest block numbers are
## deleted from the `<unprocessed>` ranges list.
##

import
  std/[algorithm, hashes, options, random, sequtils, sets, strutils],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/[byteutils, interval_set, sorted_set],
  ../../utils,
  ../protocol,
  "."/[full_desc, ticker]

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

static:
  doAssert stagedWorkItemsTrigger < maxStagedWorkItems

type
  BlockRangeSetRef* = ##\
    ## Disjunct sets of block number intervals
    IntervalSetRef[BlockNumber,UInt256]

  BlockRange* = ##\
    ## Block number interval
    Interval[BlockNumber,UInt256]

  WorkItemQueue* = ##\
    ## Block intervals sorted by least block number
    SortedSet[BlockNumber,WorkItemRef]

  WorkItemWalkRef* = ##\
    ## Fast traversal descriptor for `WorkItemQueue`
    SortedSetWalkRef[BlockNumber,WorkItemRef]

  WorkItemRef* = ref object
    ## Block worker item wrapping for downloading a block range
    blocks: BlockRange               ## Block numbers to fetch
    topHash: Option[Hash256]         ## Fetch by top hash rather than blocks
    headers: seq[BlockHeader]        ## Block headers received
    hashes: seq[Hash256]             ## Hashed from `headers[]` for convenience
    bodies: seq[BlockBody]           ## Block bodies received

  BuddyDataEx = ref object of BuddyDataRef
    ## Local descriptor data extension
    bestNumber: Option[BlockNumber]  ## Largest block number reported

  CtxDataEx = ref object of CtxDataRef
    backtrack: Option[Hash256]       ## Find reverse block after re-org
    unprocessed: BlockRangeSetRef    ## Block ranges to fetch
    staged: WorkItemQueue            ## Blocks fetched but not stored yet
    untrusted: seq[Peer]             ## Clean up list
    trusted: HashSet[Peer]           ## Peers ready for delivery
    topPersistent: BlockNumber       ## Up to this block number stored OK
    ticker: Ticker                   ## Logger ticker

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(peer: Peer): Hash =
  ## Mixin `HashSet[Peer]` handler
  hash(cast[pointer](peer))

proc `+`(n: BlockNumber; delta: static[int]): BlockNumber =
  ## Semantic sugar for expressions like `xxx.toBlockNumber + 1`
  n + delta.toBlockNumber

proc `-`(n: BlockNumber; delta: static[int]): BlockNumber =
  ## Semantic sugar for expressions like `xxx.toBlockNumber - 1`
  n - delta.toBlockNumber

proc merge(ivSet: BlockRangeSetRef; wi: WorkItemRef): Uint256 =
  ## Semantic sugar
  ivSet.merge(wi.blocks)

proc reduce(ivSet: BlockRangeSetRef; wi: WorkItemRef): Uint256 =
  ## Semantic sugar
  ivSet.reduce(wi.blocks)


proc pp(n: BlockNumber): string =
  ## Dedicated pretty printer (`$` is defined elsewhere using `UInt256`)
  if n == high(BlockNumber): "high" else:"#" & $n

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

proc local(buddy: BuddyRef): BuddyDataEx =
  ## Parameters local to this peer worker
  buddy.data.BuddyDataEx

proc pool(ctx: CtxRef): CtxDataEx =
  ## Parameters shared between all peer workers
  ctx.data.CtxDataEx

proc pool(buddy: BuddyRef): CtxDataEx =
  ## Ditto
  buddy.ctx.data.CtxDataEx

proc nextUnprocessed(pool: CtxDataEx): Option[BlockNumber] =
  ## Pseudo getter, logging helper
  let rc = pool.unprocessed.ge()
  if rc.isOK:
    result = some(rc.value.minPt)

proc nextStaged(pool: CtxDataEx): Option[BlockRange] =
  ## Pseudo getter, logging helper
  let rc = pool.staged.ge(low(BlockNumber))
  if rc.isOK:
    result = some(rc.value.data.blocks)

# ------------------------------------------------------------------------------
# Private functions affecting all shared data
# ------------------------------------------------------------------------------

proc globalReset(ctx: CtxRef; backBlocks = maxHeadersFetch): bool =
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

  ctx.pool.unprocessed.clear()
  ctx.pool.staged.clear()
  ctx.pool.trusted.clear()
  ctx.pool.topPersistent = topPersistent
  discard ctx.pool.unprocessed.merge(topPersistent + 1, high(BlockNumber))

  true

proc tickerUpdater(ctx: CtxRef): TickerStatsUpdater =
  result = proc: TickerStats =
    let
      stagedRange = ctx.pool.nextStaged
      nextStaged = if stagedRange.isSome: some(stagedRange.get.minPt)
                   else: none(BlockNumber)
    TickerStats(
      topPersistent:   ctx.pool.topPersistent,
      nextStaged:      nextStaged,
      nextUnprocessed: ctx.pool.nextUnprocessed,
      nStagedQueue:    ctx.pool.staged.len,
      reOrg:           ctx.pool.backtrack.isSome)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template safeTransport(buddy: BuddyRef; info: static[string]; code: untyped) =
  try:
    code
  except TransportError as e:
    error info & " => stop", error=($e.name), msg=e.msg
    buddy.ctrl.stopped = true


proc getRandomTrustedPeer(buddy: BuddyRef): Result[Peer,void] =
  ## Return random entry from `trusted` peer different from this peer set if
  ## there are enough
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `randomTrustedPeer()`
  let
    nPeers = buddy.pool.trusted.len
    offInx = if buddy.peer in buddy.pool.trusted: 2 else: 1
  if 0 < nPeers:
    var (walkInx, stopInx) = (0, rand(nPeers - offInx))
    for p in buddy.pool.trusted:
      if p == buddy.peer:
        continue
      if walkInx == stopInx:
        return ok(p)
      walkInx.inc
  err()


proc newWorkItem(buddy: BuddyRef): Result[WorkItemRef,void] =
  ## Fetch the next unprocessed block range and register it as work item.
  ##
  ## This function will grab a block range from the `unprocessed` range set,
  ## ove it and return it as a `WorkItemRef`. The returned range is registered
  ## in the `pending` list.
  let
    peer = buddy.peer
    rc = buddy.pool.unprocessed.ge()
  if rc.isErr:
      return err() # no more data for this peer

  # Check whether there is somthing to do at all
  if buddy.local.bestNumber.isNone or
     buddy.local.bestNumber.get < rc.value.minPt:
    return err() # no more data for this peer

  # Compute interval
  let iv = BlockRange.new(
    rc.value.minPt,
    min(rc.value.maxPt,
        min(rc.value.minPt + maxHeadersFetch - 1,
            buddy.local.bestNumber.get)))

  discard buddy.pool.unprocessed.reduce(iv)
  return ok(WorkItemRef(blocks: iv))


proc recycleStaged(buddy: BuddyRef) =
  ## Flush list of staged items and store the block ranges
  ## back to the `unprocessed` ranges set
  ##
  # using fast traversal
  let walk = WorkItemWalkRef.init(buddy.pool.staged)
  var rc = walk.first()
  while rc.isOk:
    # Store back into `unprocessed` ranges set
    discard buddy.pool.unprocessed.merge(rc.value.data)
    rc = walk.next()
  # optional clean up, see comments on the destroy() directive
  walk.destroy()
  buddy.pool.staged.clear()

# ------------------------------------------------------------------------------
# Private `Future` helpers
# ------------------------------------------------------------------------------

proc getBestNumber(buddy: BuddyRef): Future[Result[BlockNumber,void]]{.async.} =
  ## Get best block number from best block hash.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `getBestBlockNumber()`
  let
    peer = buddy.peer
    startHash = peer.state(eth).bestBlockHash
    reqLen = 1u
    hdrReq = BlocksRequest(
      startBlock: HashOrNum(
        isHash:   true,
        hash:     startHash),
      maxResults: reqLen,
      skip:       0,
      reverse:    true)

  trace trEthSendSendingGetBlockHeaders, peer,
    startBlock=startHash.data.toHex, reqLen

  var hdrResp: Option[blockHeadersObj]
  buddy.safeTransport("Error fetching block header"):
    hdrResp = await peer.getBlockHeaders(hdrReq)
  if buddy.ctrl.stopped:
    return err()

  if hdrResp.isNone:
    trace trEthRecvReceivedBlockHeaders, peer, reqLen, respose="n/a"
    return err()

  let hdrRespLen = hdrResp.get.headers.len
  if hdrRespLen == 1:
    let blockNumber = hdrResp.get.headers[0].blockNumber
    trace trEthRecvReceivedBlockHeaders, peer, hdrRespLen, blockNumber
    return ok(blockNumber)

  trace trEthRecvReceivedBlockHeaders, peer, reqLen, hdrRespLen
  return err()


proc agreesOnChain(buddy: BuddyRef; other: Peer): Future[bool] {.async.} =
  ## Returns `true` if one of the peers `buddy.peer` or `p` acknowledges
  ## existence of the best block of the other peer.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `peersAgreeOnChain()`
  var
    peer = buddy.peer
    start = peer
    fetch = other
  if fetch.state(eth).bestDifficulty < start.state(eth).bestDifficulty:
    swap(fetch, start)

  let
    startHash = start.state(eth).bestBlockHash
    hdrReq = BlocksRequest(
      startBlock: HashOrNum(
        isHash:   true,
        hash:     startHash),
      maxResults: 1,
      skip:       0,
      reverse:    true)

  trace trEthSendSendingGetBlockHeaders, peer, start, fetch,
    startBlock=startHash.data.toHex, hdrReqLen=1

  var hdrResp: Option[blockHeadersObj]
  buddy.safeTransport("Error fetching block header"):
    hdrResp = await fetch.getBlockHeaders(hdrReq)
  if buddy.ctrl.stopped:
    return false

  if hdrResp.isSome:
    let hdrRespLen = hdrResp.get.headers.len
    if 0 < hdrRespLen:
      let blockNumber = hdrResp.get.headers[0].blockNumber
      trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
        hdrRespLen, blockNumber
    return true

  trace trEthRecvReceivedBlockHeaders, peer, start, fetch,
    blockNumber="n/a"

# ------------------------------------------------------------------------------
# Private functions, worker sub-tasks
# ------------------------------------------------------------------------------

proc initaliseWorker(buddy: BuddyRef): Future[bool] {.async.} =
  ## Initalise worker. This function must be run in single mode at the
  ## beginning of running worker peer.
  ##
  ## Ackn: nim-eth/eth/p2p/blockchain_sync.nim: `startSyncWithPeer()`
  ##
  let peer = buddy.peer

  # Delayed clean up batch list
  if 0 < buddy.pool.untrusted.len:
    trace "Removing untrused peers", peer, count=buddy.pool.untrusted.len
    for p in buddy.pool.untrusted:
      buddy.pool.trusted.excl p
    buddy.pool.untrusted.setLen(0)

  if buddy.local.bestNumber.isNone:
    let rc = await buddy.getBestNumber()
    # Beware of peer terminating the session right after communicating
    if rc.isErr or buddy.ctrl.stopped:
      return false
    if rc.value <= buddy.pool.topPersistent:
      buddy.ctrl.zombie = true
      trace "Useless peer, best number too low", peer,
        topPersistent=buddy.pool.topPersistent, bestNumber=rc.value
    buddy.local.bestNumber = some(rc.value)

  if minPeersToStartSync <= buddy.pool.trusted.len:
    # We have enough trusted peers. Validate new peer against trusted
    let rc = buddy.getRandomTrustedPeer()
    if rc.isOK:
      if await buddy.agreesOnChain(rc.value):
        # Beware of peer terminating the session
        if not buddy.ctrl.stopped:
          buddy.pool.trusted.incl peer
          return true

  # If there are no trusted peers yet, assume this very peer is trusted,
  # but do not finish initialisation until there are more peers.
  elif buddy.pool.trusted.len == 0:
    trace "Assume initial trusted peer", peer
    buddy.pool.trusted.incl peer

  elif buddy.pool.trusted.len == 1 and buddy.peer in buddy.pool.trusted:
    # Ignore degenerate case, note that `trusted.len < minPeersToStartSync`
    discard

  else:
    # At this point we have some "trusted" candidates, but they are not
    # "trusted" enough. We evaluate `peer` against all other candidates. If
    # one of the candidates disagrees, we swap it for `peer`. If all candidates
    # agree, we add `peer` to trusted set. The peers in the set will become
    # "fully trusted" (and sync will start) when the set is big enough
    var
      agreeScore = 0
      otherPeer: Peer
    for p in buddy.pool.trusted:
      if peer == p:
        inc agreeScore
      else:
        let agreedOk = await buddy.agreesOnChain(p)
        # Beware of peer terminating the session
        if buddy.ctrl.stopped:
          return false
        if agreedOk:
          inc agreeScore
        else:
          otherPeer = p

    # Check for the number of peers that disagree
    case buddy.pool.trusted.len - agreeScore
    of 0:
      trace "Peer trusted by score", peer,
        trusted=buddy.pool.trusted.len
      buddy.pool.trusted.incl peer # best possible outcome
    of 1:
      trace "Other peer no longer trusted", peer,
        otherPeer, trusted=buddy.pool.trusted.len
      buddy.pool.trusted.excl otherPeer
      buddy.pool.trusted.incl peer
    else:
      trace "Peer not trusted", peer,
        trusted=buddy.pool.trusted.len
      discard

    if minPeersToStartSync <= buddy.pool.trusted.len:
      return true


proc fetchHeaders(buddy: BuddyRef; wi: WorkItemRef): Future[bool] {.async.} =
  ## Get the work item with the least interval and complete it. The function
  ## returns `true` if bodies were fetched and there were no inconsistencies.
  let peer = buddy.peer

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
    discard buddy.pool.unprocessed.reduce(wi)
    trace "Updated reverse header range", peer, range=($wi.blocks)

  # Verify start block number
  elif hdrResp.get.headers[0].blockNumber != wi.blocks.minPt:
    trace "Header range starts with wrong block number => zombify", peer,
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
    discard buddy.pool.unprocessed.merge(redRng.maxPt + 1, wi.blocks.maxPt)
    wi.blocks = redRng

  return true


proc fetchBodies(buddy: BuddyRef; wi: WorkItemRef): Future[bool] {.async.} =
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


proc stageItem(buddy: BuddyRef; wi: WorkItemRef) =
  ## Add work item to the list of staged items
  let peer = buddy.peer

  let rc = buddy.pool.staged.insert(wi.blocks.minPt)
  if rc.isOk:
    rc.value.data = wi

    # Turn on pool mode if there are too may staged work items queued.
    # This must only be done when the added work item is not backtracking.
    if not buddy.pool.backtrack.isSome and
       stagedWorkItemsTrigger < buddy.pool.staged.len:
      buddy.ctx.poolMode = true

    # The list size is limited. So cut if necessary and recycle back the block
    # range of the discarded item (tough luck if the current work item is the
    # one removed from top.)
    while maxStagedWorkItems < buddy.pool.staged.len:
      let topValue = buddy.pool.staged.le(high(BlockNumber)).value
      discard buddy.pool.unprocessed.merge(topValue.data)
      discard buddy.pool.staged.delete(topValue.key)
    return

  # Ooops, duplicates should not exist (but anyway ...)
  let wj = block:
    let rc = buddy.pool.staged.eq(wi.blocks.minPt)
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
      discard buddy.pool.unprocessed.merge(rc.value)


proc processStaged(buddy: BuddyRef): bool =
  ## Fetch a work item from the `staged` queue an process it to be
  ## stored on the persistent block chain.

  let
    peer = buddy.peer
    chainDb = buddy.ctx.chain
    rc = buddy.pool.staged.ge(low(BlockNumber))
  if rc.isErr:
    # No more items in the database
    return false

  let
    wi = rc.value.data
    topPersistent = buddy.pool.topPersistent
    startNumber = wi.headers[0].blockNumber
    stagedRecords = buddy.pool.staged.len

  # Check whether this record of blocks can be stored, at all
  if topPersistent + 1 < startNumber:
    trace "Staged work item postponed", peer, topPersistent,
      range=($wi.blocks), stagedRecords
    return false

  # Ok, store into the block chain database
  trace "Processing staged work item", peer,
    topPersistent, range=($wi.blocks)

  # remove from staged DB
  discard buddy.pool.staged.delete(wi.blocks.minPt)

  try:
    if chainDb.persistBlocks(wi.headers, wi.bodies) == ValidationResult.OK:
      buddy.pool.topPersistent = wi.blocks.maxPt
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
      trace "Storing persistent blocks failed => zombify", peer,
        range=($wi.blocks)
      discard buddy.pool.unprocessed.merge(wi.blocks)
      buddy.ctrl.zombie = true
      return false
  except CatchableError as e:
    error "Failed to access parent blocks", peer,
      blockNumber=wi.headers[0].blockNumber.pp, error=($e.name), msg=e.msg

  # Parent block header problem, so we might be in the middle of a re-org.
  # Set single mode backtrack following the offending parent hash.
  buddy.pool.backtrack = some(parentHash)
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

proc workerSetup*(ctx: CtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.data = CtxDataEx(unprocessed: BlockRangeSetRef.init()) # `pool` extension
  ctx.pool.staged.init()
  if tickerOK:
    ctx.pool.ticker = Ticker.init(ctx.tickerUpdater)
  else:
    debug "Ticker is disabled"
  return ctx.globalReset(0)

proc workerRelease*(ctx: CtxRef) =
  ## Global clean up
  if not ctx.pool.ticker.isNil:
    ctx.pool.ticker.stop()

proc start*(buddy: BuddyRef): bool =
  ## Initialise `WorkerBuddy` to support `workerBlockHeaders()` calls
  if buddy.peer.supports(protocol.eth) and
     buddy.peer.state(protocol.eth).initialized:
    buddy.data = BuddyDataEx.new() # `local` extension
    if not buddy.pool.ticker.isNil:
      buddy.pool.ticker.startBuddy()
    return true

proc stop*(buddy: BuddyRef) =
  ## Clean up this peer
  buddy.ctrl.stopped = true
  buddy.pool.untrusted.add buddy.peer
  if not buddy.pool.ticker.isNil:
     buddy.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runSingle*(buddy: BuddyRef) {.async.} =
  ## This peer worker is invoked if the peer-local flag `buddy.ctrl.multiOk`
  ## is set `false` which is the default mode. This flag is updated by the
  ## worker when deemed appropriate.
  ## * For all workers, there can be only one `runSingle()` function activated
  ##   simultaneously.
  ## * There will be no `runPool()` function iteration activated simultaneously.
  ## * There will be no `runMulti()` function activated for the same peer
  ##   simultaneously
  ##
  ## Note that this function runs in `async` mode.
  ##
  let peer = buddy.peer

  if buddy.pool.backtrack.isSome:
    trace "Single run mode, re-org backtracking", peer
    let wi = WorkItemRef(
      # This dummy interval can savely merged back without any effect
      blocks:  BlockRange.new(high(BlockNumber),high(BlockNumber)),
      # Enable backtrack
      topHash: some(buddy.pool.backtrack.get))

    # Fetch headers and bodies for the current work item
    if await buddy.fetchHeaders(wi):
      if await buddy.fetchBodies(wi):
        buddy.pool.backtrack = none(Hash256)
        buddy.stageItem(wi)

        # Update pool and persistent database (may reset `multiOk`)
        buddy.ctrl.multiOk = true
        while buddy.processStaged():
          discard
        return

    # This work item failed, nothing to do anymore.
    discard buddy.pool.unprocessed.merge(wi)
    buddy.ctrl.zombie = true

  else:
    if buddy.local.bestNumber.isNone:
      # Only log for the first time, or so
      trace "Single run mode, initialisation", peer,
        trusted=buddy.pool.trusted.len
      discard

    # Initialise/re-initialise this worker
    if await buddy.initaliseWorker():
      buddy.ctrl.multiOk = true
    elif not buddy.ctrl.stopped:
      await sleepAsync(2.seconds)


proc runPool*(buddy: BuddyRef) =
  ## Ocne started, the function `runPool()` is called for all worker peers in
  ## a row (as the body of an iteration.) There will be no other worker peer
  ## function be activated simultaneously.
  ##
  ## This instance is activated if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It is the responsibility of the `runPool()`
  ## instance to reset the flag `buddy.ctx.poolMode`, typically at the first
  ## instance invoked as the number of active instances is unknown to the
  ## worker peer.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  if buddy.ctx.poolMode:
    discard buddy.pool.unprocessed.merge(
      buddy.pool.topPersistent + 1, high(UInt256))
    buddy.ctx.poolMode = false


proc runMulti*(buddy: BuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  # Fetch work item
  let rc = buddy.newWorkItem()
  if rc.isErr:
    # No way, end of capacity for this peer => re-calibrate
    buddy.ctrl.multiOk = false
    buddy.local.bestNumber = none(BlockNumber)
    return
  let wi = rc.value

  # Fetch headers and bodies for the current work item
  if await buddy.fetchHeaders(wi):
    if await buddy.fetchBodies(wi):
      buddy.stageItem(wi)

      # Update pool and persistent database
      while buddy.processStaged():
        discard
      return

  # This work item failed
  discard buddy.pool.unprocessed.merge(wi)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# Nimbus - Rapidly converge on and track the canonical chain head of each peer
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module fetches and tracks the canonical chain head of each connected
## peer.  (Or in future, each peer we care about; we won't poll them all so
## often.)
##
## This is for when we aren't sure of the block number of a peer's canonical
## chain head.  Most of the time, after finding which block, it quietly polls
## to track small updates to the "best" block number and hash of each peer.
##
## But sometimes that can get out of step.  If there has been a deeper reorg
## than our tracking window, or a burst of more than a few new blocks, network
## delays, downtime, or the peer is itself syncing.  Perhaps we stopped Nimbus
## and restarted a while later, e.g. suspending a laptop or Control-Z.  Then
## this will catch up.  It is even possible that the best hash the peer gave us
## in the `Status` handshake has disappeared by the time we query for the
## corresponding block number, so we start at zero.
##
## The steps here perform a robust and efficient O(log N) search to rapidly
## converge on the new best block if it's moved out of the polling window no
## matter where it starts, confirm the peer's canonical chain head boundary,
## then track the peer's chain head in real-time by polling.  The method is
## robust to peer state changes at any time.
##
## The purpose is to:
##
## - Help with finding a peer common chain prefix ("fast sync pivot") in a
##   consistent, fast and explicit way.
##
## - Catch up quickly after any long pauses of network downtime, program not
##   running, or deep chain reorgs.
##
## - Be able to display real-time peer states, so they are less mysterious.
##
## - Tell the beam/snap/trie sync processes when to start and what blocks to
##   fetch, and keep those fetchers in the head-adjacent window of the
##   ever-changing chain.
##
## - Help the sync process bootstrap usefully when we only have one peer,
##   speculatively fetching and validating what data we can before we have more
##   peers to corroborate the consensus.
##
## - Help detect consensus failures in the network.
##
## We cannot assume a peer's canonical chain stays the same or only gains new
## blocks from one query to the next.  There can be reorgs, including deep
## reorgs.  When a reorg happens, the best block number can decrease if the new
## canonical chain is shorter than the old one, and the best block hash we
## previously knew can become unavailable on the peer.  So we must detect when
## the current best block disappears and be able to reduce block number.

import
  std/bitops,
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, p2p/private/p2p_types],
  "../../.."/[constants, genesis, p2p/chain/chain_desc],
  "../.."/[protocol, sync_desc, types],
  ../worker_desc

{.push raises: [Defect].}

export
  worker_desc

logScope:
  topics = "snap-pivot"

const
  syncLockedMinimumReply    = 8
    ## Minimum number of headers we assume any peers will send if they have
    ## them in contiguous ascending queries.  Fewer than this confirms we have
    ## found the peer's canonical chain head boundary.  Must be at least 2, and
    ## at least `syncLockedQueryOverlap+2` to stay `SyncLocked` when the chain
    ## extends.  Should not be large as that would be stretching assumptions
    ## about peer implementations.  8 is chosen as it allows 3-deep extensions
    ## and 3-deep reorgs to be followed in a single round trip.

  syncLockedQueryOverlap    = 4
    ## Number of headers to re-query on each poll when `SyncLocked` so that we
    ## get small reorg updates in one round trip.  Must be no more than
    ## `syncLockedMinimumReply-1`, no more than `syncLockedMinimumReply-2` to
    ## stay `SyncLocked` when the chain extends, and not too large to avoid
    ## excessive duplicate fetching.  4 is chosen as it allows 3-deep reorgs
    ## to be followed in single round trip.

  syncLockedQuerySize       = 192
    ## Query size when polling `SyncLocked`.  Must be at least
    ## `syncLockedMinimumReply`.  Large is fine, if we get a large reply the
    ## values are almost always useful.

  huntQuerySize             = 16
    ## Query size when hunting for canonical head boundary.  Small is good
    ## because we don't want to keep most of the headers at hunt time.

  huntForwardExpandShift    = 4
    ## Expansion factor during `HuntForward` exponential search.
    ## 16 is chosen for rapid convergence when bootstrapping or catching up.

  huntBackwardExpandShift   = 1
    ## Expansion factor during `HuntBackward` exponential search.
    ## 2 is chosen for better convergence when tracking a chain reorg.

type
  WorkerMode = enum
    ## The current state of tracking the peer's canonical chain head.
    ## `bestBlockNumber` is only valid when this is `SyncLocked`.
    SyncLocked
    SyncOnlyHash
    HuntForward
    HuntBackward
    HuntRange
    HuntRangeFinal

  WorkerHuntEx = ref object of WorkerPivotBase
    ## Peer canonical chain head ("best block") search state.
    syncMode:      WorkerMode    ## Action mode
    lowNumber:     BlockNumber   ## Recent lowest known block number.
    highNumber:    BlockNumber   ## Recent highest known block number.
    bestNumber:    BlockNumber
    bestHash:      BlockHash
    step:          uint

static:
  doAssert syncLockedMinimumReply >= 2
  doAssert syncLockedMinimumReply >= syncLockedQueryOverlap + 2
  doAssert syncLockedQuerySize <= maxHeadersFetch
  doAssert huntQuerySize >= 1 and huntQuerySize <= maxHeadersFetch
  doAssert huntForwardExpandShift >= 1 and huntForwardExpandShift <= 8
  doAssert huntBackwardExpandShift >= 1 and huntBackwardExpandShift <= 8

  # Make sure that request/response wire protocol messages are id-tracked and
  # would not overlap (no multi-protocol legacy support)
  doAssert 66 <= protocol.ethVersion

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hunt(buddy: SnapBuddyRef): WorkerHuntEx =
  buddy.data.workerPivot.WorkerHuntEx

proc `hunt=`(buddy: SnapBuddyRef; value: WorkerHuntEx) =
  buddy.data.workerPivot = value

proc new(T: type WorkerHuntEx; syncMode: WorkerMode): T =
  T(syncMode:   syncMode,
    lowNumber:  0.toBlockNumber.BlockNumber,
    highNumber: high(BlockNumber).BlockNumber, # maximum uncertainty range.
    bestNumber: 0.toBlockNumber.BlockNumber,
    bestHash:   ZERO_HASH256.BlockHash,        # whatever
    step:       0u)

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

proc traceSyncLocked(buddy: SnapBuddyRef, num: BlockNumber, hash: BlockHash) =
  ## Trace messages when peer canonical head is confirmed or updated.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    bestBlock = ctx.pp(hash, num)
  if buddy.hunt.syncMode != SyncLocked:
    debug "Now tracking chain head of peer", peer,
      bestBlock
  elif num > buddy.hunt.bestNumber:
    if num == buddy.hunt.bestNumber + 1:
      debug "Peer chain head advanced one block", peer,
        advance=1, bestBlock
    else:
      debug "Peer chain head advanced some blocks", peer,
        advance=(buddy.hunt.bestNumber - num), bestBlock
  elif num < buddy.hunt.bestNumber or hash != buddy.hunt.bestHash:
    debug "Peer chain head reorg detected", peer,
      advance=(buddy.hunt.bestNumber - num), bestBlock

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc clearSyncStateRoot(buddy: SnapBuddyRef) =
  if buddy.data.pivotHeader.isSome:
    debug "Stopping state sync from this peer", peer=buddy.peer
    buddy.data.pivotHeader = none(BlockHeader)

proc lockSyncStateAndFetch(buddy: SnapBuddyRef; header: BlockHeader) =
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = header.stateRoot
    hash = header.blockHash.BlockHash
    thisBlock = ctx.pp(hash, header.blockNumber)

  buddy.traceSyncLocked(header.blockNumber, hash)
  buddy.hunt.bestNumber = header.blockNumber
  buddy.hunt.bestHash = hash
  buddy.hunt.syncMode = SyncLocked

  if buddy.data.pivotHeader.isNone:
    debug "Starting state sync from this peer", peer, thisBlock, stateRoot
  elif buddy.data.pivotHeader.unsafeGet.stateRoot != stateRoot:
    trace "Adjusting state sync root from this peer", peer, thisBlock, stateRoot

  buddy.data.pivotHeader = some(header)

proc setHuntBackward(buddy: SnapBuddyRef, lowestAbsent: BlockNumber) =
  ## Start exponential search mode backward due to new uncertainty.
  buddy.hunt.syncMode = HuntBackward
  buddy.hunt.step = 0
  # Block zero is always present.
  buddy.hunt.lowNumber = 0.toBlockNumber
  # Zero `lowestAbsent` is never correct, but an incorrect peer could send it.
  buddy.hunt.highNumber =
          if lowestAbsent > 0: lowestAbsent
          else: 1.toBlockNumber
  buddy.clearSyncStateRoot()

proc setHuntForward(buddy: SnapBuddyRef, highestPresent: BlockNumber) =
  ## Start exponential search mode forward due to new uncertainty.
  buddy.hunt.syncMode = HuntForward
  buddy.hunt.step = 0
  buddy.hunt.lowNumber = highestPresent
  buddy.hunt.highNumber = high(BlockNumber)
  buddy.clearSyncStateRoot()

proc updateHuntAbsent(buddy: SnapBuddyRef, lowestAbsent: BlockNumber) =
  ## Converge uncertainty range backward.
  if lowestAbsent < buddy.hunt.highNumber:
    buddy.hunt.highNumber = lowestAbsent
    # If uncertainty range has moved outside the search window, change to hunt
    # backward to block zero.  Note that empty uncertainty range is allowed
    # (empty range is `hunt.lowNumber + 1 == hunt.highNumber`).
    if buddy.hunt.highNumber <= buddy.hunt.lowNumber:
      buddy.setHuntBackward(lowestAbsent)
  buddy.clearSyncStateRoot()

proc updateHuntPresent(buddy: SnapBuddyRef, highestPresent: BlockNumber) =
  ## Converge uncertainty range forward.
  if highestPresent > buddy.hunt.lowNumber:
    buddy.hunt.lowNumber = highestPresent
    # If uncertainty range has moved outside the search window, change to hunt
    # forward to no upper limit.  Note that empty uncertainty range is allowed
    # (empty range is `hunt.lowNumber + 1 == hunt.highNumber`).
    if buddy.hunt.lowNumber >= buddy.hunt.highNumber:
      buddy.setHuntForward(highestPresent)
  buddy.clearSyncStateRoot()

# ------------------------------------------------------------------------------
# Private functions, assemble request
# ------------------------------------------------------------------------------

proc peerSyncChainRequest(buddy: SnapBuddyRef): BlocksRequest =
  ## Choose `GetBlockHeaders` parameters when hunting or following the canonical
  ## chain of a peer.
  if buddy.hunt.syncMode == SyncLocked:
    # Stable and locked.  This is just checking for changes including reorgs.
    # `buddy.hunt.bestNumber` was recently the head of the peer's canonical
    # chain.  We must include this block number to detect when the canonical
    # chain gets shorter versus no change.
    result.startBlock.number =
        if buddy.hunt.bestNumber <= syncLockedQueryOverlap:
          # Every peer should send genesis for block 0, so don't ask for it.
          # `peerSyncChainEmptyReply` has logic to handle this reply as if it
          # was for block 0.  Aside from saving bytes, this is more robust if
          # some client doesn't do genesis reply correctly.
          1.toBlockNumber
        else:
          min(buddy.hunt.bestNumber - syncLockedQueryOverlap.toBlockNumber,
              high(BlockNumber) - (syncLockedQuerySize - 1).toBlockNumber)
    result.maxResults = syncLockedQuerySize
    return

  if buddy.hunt.syncMode == SyncOnlyHash:
    # We only have the hash of the recent head of the peer's canonical chain.
    # Like `SyncLocked`, query more than one item to detect when the
    # canonical chain gets shorter, no change or longer.
    result.startBlock = buddy.hunt.bestHash.to(HashOrNum)
    result.maxResults = syncLockedQuerySize
    return

  # Searching for the peers's canonical head.  An ascending query is always
  # used, regardless of search direction. This is because a descending query
  # (`reverse = true` and `maxResults > 1`) is useless for searching: Either
  # `startBlock` is present, in which case the extra descending results
  # contribute no more information about the canonical head boundary, or
  # `startBlock` is absent in which case there are zero results.  It's not
  # defined in the `eth` specification that there must be zero results (in
  # principle peers could return the lower numbered blocks), but in practice
  # peers stop at the first absent block in the sequence from `startBlock`.
  #
  # Guaranteeing O(log N) time convergence in all scenarios requires some
  # properties to be true in both exponential search (expanding) and
  # quasi-binary search (converging in a range).  The most important is that
  # the gap to `startBlock` after `hunt.lowNumber` and also before
  # `hunt.highNumber` are proportional to the query step, where the query step
  # is `hunt.step` exponentially expanding each round, or `maxStep`
  # approximately evenly distributed in the range.
  #
  # `hunt.lowNumber+1` must not be used consistently as the start, even with a
  # large enough query step size, as that will sometimes take O(N) to converge
  # in both the exponential and quasi-binary searches.  (Ending at
  # `hunt.highNumber-1` is fine if `huntQuerySize > 1`.  This asymmetry is
  # due to ascending queries (see earlier comment), and non-empty truncated
  # query reply being proof of presence before the truncation point, but not
  # proof of absence after it.  A reply can be truncated just because the peer
  # decides to.)
  #
  # The proportional gap requirement is why we divide by query size here,
  # instead of stretching to fit more strictly with `(range-1)/(size-1)`.

  const huntFinalSize = max(2, huntQuerySize)
  var maxStep = 0u

  let fullRangeClamped =
    if buddy.hunt.highNumber <= buddy.hunt.lowNumber: 0u
    else: min(high(uint).toBlockNumber,
              buddy.hunt.highNumber - buddy.hunt.lowNumber).truncate(uint) - 1

  if fullRangeClamped >= huntFinalSize: # `HuntRangeFinal` condition.
    maxStep = if huntQuerySize == 1:
                fullRangeClamped
              elif (huntQuerySize and (huntQuerySize-1)) == 0:
                fullRangeClamped shr fastLog2(huntQuerySize)
              else:
                fullRangeClamped div huntQuerySize
    doAssert huntFinalSize >= huntQuerySize
    doAssert maxStep >= 1 # Ensured by the above assertion.

  # Check for exponential search (expanding).  Iterate `hunt.step`.  O(log N)
  # requires `startBlock` to be offset from `hunt.lowNumber`/`hunt.highNumber`.
  if buddy.hunt.syncMode in {HuntForward, HuntBackward} and
     fullRangeClamped >= huntFinalSize:
    let forward = buddy.hunt.syncMode == HuntForward
    let expandShift = if forward: huntForwardExpandShift
                      else: huntBackwardExpandShift
    # Switches to range search when this condition is no longer true.
    if buddy.hunt.step < maxStep shr expandShift:
      # The `if` above means the next line cannot overflow.
      buddy.hunt.step = if buddy.hunt.step > 0: buddy.hunt.step shl expandShift
                        else: 1
      # Satisfy the O(log N) convergence conditions.
      result.startBlock.number =
        if forward: buddy.hunt.lowNumber + buddy.hunt.step.toBlockNumber
        else: buddy.hunt.highNumber -
                 (buddy.hunt.step * huntQuerySize).toBlockNumber
      result.maxResults = huntQuerySize
      result.skip = buddy.hunt.step - 1
      return

  # For tracing/display.
  buddy.hunt.step = maxStep
  buddy.hunt.syncMode = HuntRange
  if maxStep > 0:
    # Quasi-binary search (converging in a range).  O(log N) requires
    # `startBlock` to satisfy the constraints described above, with the
    # proportionality from both ends of the range.  The optimal information
    # gathering position is tricky and doesn't make much difference, so don't
    # bother.  We'll centre the query in the range.
    var offset = fullRangeClamped - maxStep * (huntQuerySize-1)
    # Rounding must bias towards end to ensure `offset >= 1` after this.
    offset -= offset shr 1
    result.startBlock.number = buddy.hunt.lowNumber + offset.toBlockNumber
    result.maxResults = huntQuerySize
    result.skip = maxStep - 1
  else:
    # Small range, final step.  At `fullRange == 0` we must query at least one
    # block before and after the range to confirm the canonical head boundary,
    # or find it has moved.  This ensures progress without getting stuck.  When
    # `fullRange` is small this is also beneficial, to get `SyncLocked` in one
    # round trip from hereand it simplifies the other search branches below.
    # Ideally the query is similar to `SyncLocked`, enough to get `SyncLocked`
    # in one round trip, and accommodate a small reorg or extension.
    const afterSoftMax = syncLockedMinimumReply - syncLockedQueryOverlap
    const beforeHardMax = syncLockedQueryOverlap
    let extra = huntFinalSize - fullRangeClamped
    var before = (extra + 1) shr 1
    before = max(before + afterSoftMax, extra) - afterSoftMax
    before = min(before, beforeHardMax)
    # See `SyncLocked` case.
    result.startBlock.number =
      if buddy.hunt.bestNumber <= before.toBlockNumber: 1.toBlockNumber
      else: min(buddy.hunt.bestNumber - before.toBlockNumber,
                high(BlockNumber) - (huntFinalSize - 1).toBlockNumber)
    result.maxResults = huntFinalSize
    buddy.hunt.syncMode = HuntRangeFinal

# ------------------------------------------------------------------------------
# Private functions, reply handling
# ------------------------------------------------------------------------------

proc peerSyncChainEmptyReply(buddy: SnapBuddyRef; request: BlocksRequest) =
  ## Handle empty `GetBlockHeaders` reply.  This means `request.startBlock` is
  ## absent on the peer.  If it was `SyncLocked` there must have been a reorg
  ## and the previous canonical chain head has disappeared.  If hunting, this
  ## updates the range of uncertainty.
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Treat empty response to a request starting from block 1 as equivalent to
  # length 1 starting from block 0 in `peerSyncChainNonEmptyReply`.  We treat
  # every peer as if it would send genesis for block 0, without asking for it.
  if request.skip == 0 and
     not request.reverse and
     not request.startBlock.isHash and
     request.startBlock.number == 1.toBlockNumber:
    try:
      buddy.lockSyncStateAndFetch(ctx.chain.Chain.db.toGenesisHeader)
    except RlpError as e:
      raiseAssert "Gensis/chain problem (" & $e.name & "): " & e.msg
    return

  if buddy.hunt.syncMode in {SyncLocked, SyncOnlyHash}:
    inc buddy.data.stats.ok.reorgDetected
    trace "Peer reorg detected, best block disappeared", peer,
      startBlock=request.startBlock

  let lowestAbsent = request.startBlock.number
  case buddy.hunt.syncMode:
  of SyncLocked:
    # If this message doesn't change our knowledge, ignore it.
    if lowestAbsent > buddy.hunt.bestNumber:
      return
    # Due to a reorg, peer's canonical head has lower block number, outside
    # our tracking window.  Sync lock is no longer valid.  Switch to hunt
    # backward to find the new canonical head.
    buddy.setHuntBackward(lowestAbsent)
  of SyncOnlyHash:
    # Due to a reorg, peer doesn't have the block hash it originally gave us.
    # Switch to hunt forward from block zero to find the canonical head.
    buddy.setHuntForward(0.toBlockNumber)
  of HuntForward, HuntBackward, HuntRange, HuntRangeFinal:
    # Update the hunt range.
    buddy.updateHuntAbsent(lowestAbsent)

  # Update best block number.  It is invalid except when `SyncLocked`, but
  # still useful as a hint of what we knew recently, for example in displays.
  if lowestAbsent <= buddy.hunt.bestNumber:
    buddy.hunt.bestNumber =
      if lowestAbsent == 0.toBlockNumber: lowestAbsent
      else: lowestAbsent - 1.toBlockNumber
    buddy.hunt.bestHash = default(typeof(buddy.hunt.bestHash))
    ctx.seen(buddy.hunt.bestHash,buddy.hunt.bestNumber)


proc peerSyncChainNonEmptyReply(
    buddy: SnapBuddyRef;
    request: BlocksRequest;
    headers: openArray[BlockHeader]) =
  ## Handle non-empty `GetBlockHeaders` reply.  This means `request.startBlock`
  ## is present on the peer and in its canonical chain (unless the request was
  ## made with a hash).  If it's a short, contiguous, ascending order reply, it
  ## reveals the abrupt transition at the end of the chain and we have learned
  ## or reconfirmed the real-time head block.  If hunting, this updates the
  ## range of uncertainty.

  let
    ctx = buddy.ctx
    len = headers.len
    highestIndex = if request.reverse: 0 else: len - 1

  # We assume a short enough reply means we've learned the peer's canonical
  # head, because it would have replied with another header if not at the head.
  # This is not justified when the request used a general hash, because the
  # peer doesn't have to reply with its canonical chain in that case, except it
  # is still justified if the hash was the known canonical head, which is
  # the case in a `SyncOnlyHash` request.
  if len < syncLockedMinimumReply and
     request.skip == 0 and not request.reverse and
     len.uint < request.maxResults:
    buddy.lockSyncStateAndFetch(headers[highestIndex])
    return

  # Be careful, this number is from externally supplied data and arithmetic
  # in the upward direction could overflow.
  let highestPresent = headers[highestIndex].blockNumber

  # A reply that isn't short enough for the canonical head criterion above
  # tells us headers up to some number, but it doesn't tell us if there are
  # more after it in the peer's canonical chain.  We have to request more
  # headers to find out.
  case buddy.hunt.syncMode:
  of SyncLocked:
    # If this message doesn't change our knowledge, ignore it.
    if highestPresent <= buddy.hunt.bestNumber:
      return
    # Sync lock is no longer valid as we don't have confirmed canonical head.
    # Switch to hunt forward to find the new canonical head.
    buddy.setHuntForward(highestPresent)
  of SyncOnlyHash:
    # As `SyncLocked` but without the block number check.
    buddy.setHuntForward(highestPresent)
  of HuntForward, HuntBackward, HuntRange, HuntRangeFinal:
    # Update the hunt range.
    buddy.updateHuntPresent(highestPresent)

  # Update best block number.  It is invalid except when `SyncLocked`, but
  # still useful as a hint of what we knew recently, for example in displays.
  if highestPresent > buddy.hunt.bestNumber:
    buddy.hunt.bestNumber = highestPresent
    buddy.hunt.bestHash = headers[highestIndex].blockHash.BlockHash
    ctx.seen(buddy.hunt.bestHash,buddy.hunt.bestNumber)

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc pivotStart*(buddy: SnapBuddyRef) =
  ## Setup state root hunter
  buddy.hunt = WorkerHuntEx.new(HuntForward)

  # We know the hash but not the block number.
  buddy.hunt.bestHash = buddy.peer.state(protocol.eth).bestBlockHash.BlockHash

  # TODO: Temporarily disabled because it's useful to test the worker.
  # buddy.syncMode = SyncOnlyHash

proc pivotStop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  discard

proc pivotRestart*(buddy: SnapBuddyRef) =
  buddy.pivotStart

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pivotExec*(buddy: SnapBuddyRef) {.async.} =
  ## Query a peer to update our knowledge of its canonical chain and its best
  ## block, which is its canonical chain head.  This can be called at any time
  ## after a peer has negotiated the connection.
  ##
  ## This function is called in an exponential then binary search style
  ## during initial sync to find the canonical head, real-time polling
  ## afterwards to check for updates.
  ##
  ## All replies to this query are part of the peer's canonical chain at the
  ## time the peer sends them.
  let
    peer = buddy.peer
    ctx = buddy.ctx

  trace "Starting pivotExec()", peer

  let
    request = buddy.peerSyncChainRequest

  trace trEthSendSendingGetBlockHeaders, peer,
    count=request.maxResults,
    startBlock=ctx.pp(request.startBlock), step=request.traceStep

  inc buddy.data.stats.ok.getBlockHeaders
  var reply: Option[protocol.blockHeadersObj]
  try:
    reply = await peer.getBlockHeaders(request)
  except CatchableError as e:
    trace trEthRecvError & "waiting for GetBlockHeaders reply", peer,
      error=e.msg
    inc buddy.data.stats.major.networkErrors
    # Just try another peer
    buddy.ctrl.zombie = true
    return

  if reply.isNone:
    trace trEthRecvTimeoutWaiting & "for GetBlockHeaders reply", peer
    # TODO: Should disconnect?
    inc buddy.data.stats.minor.timeoutBlockHeaders
    return

  let nHeaders = reply.get.headers.len
  if nHeaders == 0:
    trace trEthRecvReceivedBlockHeaders, peer,
      got=0, requested=request.maxResults
  else:
    trace trEthRecvReceivedBlockHeaders, peer,
      got=nHeaders, requested=request.maxResults,
      firstBlock=reply.get.headers[0].blockNumber,
      lastBlock=reply.get.headers[^1].blockNumber

  if request.maxResults.int < nHeaders:
    trace trEthRecvProtocolViolation & "excess headers in BlockHeaders message",
      peer, got=nHeaders, requested=request.maxResults
    # TODO: Should disconnect.
    inc buddy.data.stats.major.excessBlockHeaders
    return

  if 0 < nHeaders:
    # TODO: Check this is not copying the `headers`.
    buddy.peerSyncChainNonEmptyReply(request, reply.get.headers)
  else:
    buddy.peerSyncChainEmptyReply(request)

  trace "Done pivotExec()", peer

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

proc huntPp*(buddy: SnapBuddyRef): string =
  let hx = buddy.hunt
  result &= "(mode=" & $hx.syncMode
  result &= ",num=(" & hx.lowNumber.pp & "," & hx.highNumber.pp & ")"
  result &= ",best=(" & hx.bestNumber.pp & "," & hx.bestHash.pp & ")"
  result &= ",step=" & $hx.step
  result &= ")"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

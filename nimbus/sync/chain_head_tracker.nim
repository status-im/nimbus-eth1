# Nimbus - Rapidly converge on and track the canonical chain head of each peer
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

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

{.push raises: [Defect].}

import
  std/bitops,
  chronos, stint, chronicles, stew/byteutils,
  eth/[common/eth_types, rlp, p2p],
  eth/p2p/[rlpx, private/p2p_types, blockchain_utils, peer_pool],
  ./protocol_eth65,
  ./sync_types

const
  syncLockedMinimumReply        = 8
    ## Minimum number of headers we assume any peers will send if they have
    ## them in contiguous ascending queries.  Fewer than this confirms we have
    ## found the peer's canonical chain head boundary.  Must be at least 2, and
    ## at least `syncLockedQueryOverlap+2` to stay `SyncLocked` when the chain
    ## extends.  Should not be large as that would be stretching assumptions
    ## about peer implementations.  8 is chosen as it allows 3-deep extensions
    ## and 3-deep reorgs to be followed in a single round trip.

  syncLockedQueryOverlap        = 4
    ## Number of headers to re-query on each poll when `SyncLocked` so that we
    ## get small reorg updates in one round trip.  Must be no more than
    ## `syncLockedMinimumReply-1`, no more than `syncLockedMinimumReply-2` to
    ## stay `SyncLocked` when the chain extends, and not too large to avoid
    ## excessive duplicate fetching.  4 is chosen as it allows 3-deep reorgs
    ## to be followed in single round trip.

  syncLockedQuerySize           = 192
    ## Query size when polling `SyncLocked`.  Must be at least
    ## `syncLockedMinimumReply`.  Large is fine, if we get a large reply the
    ## values are almost always useful.

  syncHuntQuerySize             = 16
    ## Query size when hunting for canonical head boundary.  Small is good
    ## because we don't want to keep most of the headers at hunt time.

  syncHuntForwardExpandShift    = 4
    ## Expansion factor during `SyncHuntForward` exponential search.
    ## 16 is chosen for rapid convergence when bootstrapping or catching up.

  syncHuntBackwardExpandShift   = 1
    ## Expansion factor during `SyncHuntBackward` exponential search.
    ## 2 is chosen for better convergence when tracking a chain reorg.

doAssert syncLockedMinimumReply >= 2
doAssert syncLockedMinimumReply >= syncLockedQueryOverlap + 2
doAssert syncLockedQuerySize <= maxHeadersFetch
doAssert syncHuntQuerySize >= 1 and syncHuntQuerySize <= maxHeadersFetch
doAssert syncHuntForwardExpandShift >= 1 and syncHuntForwardExpandShift <= 8
doAssert syncHuntBackwardExpandShift >= 1 and syncHuntBackwardExpandShift <= 8

proc traceSyncLocked(sp: SyncPeer, bestNumber: BlockNumber, bestHash: Hash256) =
  ## Trace messages when peer canonical head is confirmed or updated.
  if sp.syncMode != SyncLocked:
    trace "Sync: Peer sync locked at last",
      peer=sp, `block`=bestNumber, hash=($bestHash)
  elif bestNumber > sp.bestBlockNumber:
    if bestNumber == sp.bestBlockNumber + 1:
      trace "Sync: Peer chain advanced one block",
        peer=sp, `block`=bestNumber, hash=($bestHash)
    else:
      trace "Sync: Peer chain advanced multiple blocks",
        peer=sp, advance=(sp.bestBlockNumber - bestNumber),
        `block`=bestNumber, hash=($bestHash)
  elif bestNumber < sp.bestBlockNumber or bestHash != sp.bestBlockHash:
    trace "Sync: Peer chain reorg detected",
      peer=sp, `block`=bestNumber, hash=($bestHash)

proc setSyncLocked(sp: SyncPeer, bestNumber: BlockNumber, bestHash: Hash256) =
  ## Actions to take when peer canonical head is confirmed or updated.
  sp.traceSyncLocked(bestNumber, bestHash)
  sp.bestBlockNumber = bestNumber
  sp.bestBlockHash = bestHash
  sp.syncMode = SyncLocked

proc setHuntBackward(sp: SyncPeer, lowestAbsent: BlockNumber) =
  ## Start exponential search mode backward due to new uncertainty.
  sp.syncMode = SyncHuntBackward
  sp.huntStep = 0
  # Block zero is always present.
  sp.huntLow = 0.toBlockNumber
  # Zero `lowestAbsent` is never correct, but an incorrect peer could send it.
  sp.huntHigh = if lowestAbsent > 0: lowestAbsent else: 1.toBlockNumber

proc setHuntForward(sp: SyncPeer, highestPresent: BlockNumber) =
  ## Start exponential search mode forward due to new uncertainty.
  sp.syncMode = SyncHuntForward
  sp.huntStep = 0
  sp.huntLow = highestPresent
  sp.huntHigh = high(BlockNumber)

proc updateHuntAbsent(sp: SyncPeer, lowestAbsent: BlockNumber) =
  ## Converge uncertainty range backward.
  if lowestAbsent < sp.huntHigh:
    sp.huntHigh = lowestAbsent
    # If uncertainty range has moved outside the search window, change to hunt
    # backward to block zero.  Note that empty uncertainty range is allowed
    # (empty range is `huntLow + 1 == huntHigh`).
    if sp.huntHigh <= sp.huntLow:
      sp.setHuntBackward(lowestAbsent)

proc updateHuntPresent(sp: SyncPeer, highestPresent: BlockNumber) =
  ## Converge uncertainty range forward.
  if highestPresent > sp.huntLow:
    sp.huntLow = highestPresent
    # If uncertainty range has moved outside the search window, change to hunt
    # forward to no upper limit.  Note that empty uncertainty range is allowed
    # (empty range is `huntLow + 1 == huntHigh`).
    if sp.huntLow >= sp.huntHigh:
      sp.setHuntForward(highestPresent)

proc peerSyncChainEmptyReply(sp: SyncPeer, request: BlocksRequest) =
  ## Handle empty `GetBlockHeaders` reply.  This means `request.startBlock` is
  ## absent on the peer.  If it was `SyncLocked` there must have been a reorg
  ## and the previous canonical chain head has disappeared.  If hunting, this
  ## updates the range of uncertainty.

  # Treat empty response from block 1 onwards as equivalent to length 1 from
  # block 0 onwards in `peerSyncChainNonEmptyReply`.  We treat every peer as if
  # it would send genesis for block 0, and don't actually ask for it.
  if request.skip == 0 and not request.reverse and
     not request.startBlock.isHash and
     request.startBlock.number == 1.toBlockNumber:
    sp.setSyncLocked(0.toBlockNumber, sp.peer.network.chain.genesisHash)
    return

  if sp.syncMode == SyncLocked or sp.syncMode == SyncOnlyHash:
    inc sp.stats.ok.reorgDetected
    trace "Sync: Peer reorg detected, best block disappeared",
      peer=sp, `block`=request.startBlock

  let lowestAbsent = request.startBlock.number
  case sp.syncMode:
    of SyncLocked:
      # If this message doesn't change our knowledge, ignore it.
      if lowestAbsent > sp.bestBlockNumber:
        return
      # Due to a reorg, peer's canonical head has lower block number, outside
      # our tracking window.  Sync lock is no longer valid.  Switch to hunt
      # backward to find the new canonical head.
      sp.setHuntBackward(lowestAbsent)
    of SyncOnlyHash:
      # Due to a reorg, peer doesn't have the block hash it originally gave us.
      # Switch to hunt forward from block zero to find the canonical head.
      sp.setHuntForward(0.toBlockNumber)
    of SyncHuntForward, SyncHuntBackward, SyncHuntRange, SyncHuntRangeFinal:
      # Update the hunt range.
      sp.updateHuntAbsent(lowestAbsent)

  # Update best block number.  It is invalid except when `SyncLocked`, but
  # still useful as a hint of what we knew recently, for example in displays.
  if lowestAbsent <= sp.bestBlockNumber:
    sp.bestBlockNumber = if lowestAbsent == 0.toBlockNumber: lowestAbsent
                         else: lowestAbsent - 1.toBlockNumber
    sp.bestBlockHash = default(typeof(sp.bestBlockHash))

proc peerSyncChainNonEmptyReply(sp: SyncPeer, request: BlocksRequest,
                                headers: openArray[BlockHeader]) =
  ## Handle non-empty `GetBlockHeaders` reply.  This means `request.startBlock`
  ## is present on the peer and in its canonical chain (unless the request was
  ## made with a hash).  If it's a short, contiguous, ascending order reply, it
  ## reveals the abrupt transition at the end of the chain and we have learned
  ## or reconfirmed the real-time head block.  If hunting, this updates the
  ## range of uncertainty.

  let len = headers.len
  let highestIndex = if request.reverse: 0 else: len - 1

  # We assume a short enough reply means we've learned the peer's canonical
  # head, because it would have replied with another header if not at the head.
  # This is not justified when the request used a general hash, because the
  # peer doesn't have to reply with its canonical chain in that case, except it
  # is still justified if the hash was the known canonical head, which is
  # the case in a `SyncOnlyHash` request.
  if len < syncLockedMinimumReply and
     request.skip == 0 and not request.reverse and
     len.uint < request.maxResults:
    sp.setSyncLocked(headers[highestIndex].blockNumber,
                     headers[highestIndex].blockHash)
    return

  # Be careful, this number is from externally supplied data and arithmetic
  # in the upward direction could overflow.
  let highestPresent = headers[highestIndex].blockNumber

  # A reply that isn't short enough for the canonical head criterion above
  # tells us headers up to some number, but it doesn't tell us if there are
  # more after it in the peer's canonical chain.  We have to request more
  # headers to find out.
  case sp.syncMode:
    of SyncLocked:
      # If this message doesn't change our knowledge, ignore it.
      if highestPresent <= sp.bestBlockNumber:
        return
      # Sync lock is no longer valid as we don't have confirmed canonical head.
      # Switch to hunt forward to find the new canonical head.
      sp.setHuntForward(highestPresent)
    of SyncOnlyHash:
      # As `SyncLocked` but without the block number check.
      sp.setHuntForward(highestPresent)
    of SyncHuntForward, SyncHuntBackward, SyncHuntRange, SyncHuntRangeFinal:
      # Update the hunt range.
      sp.updateHuntPresent(highestPresent)

  # Update best block number.  It is invalid except when `SyncLocked`, but
  # still useful as a hint of what we knew recently, for example in displays.
  if highestPresent > sp.bestBlockNumber:
    sp.bestBlockNumber = highestPresent
    sp.bestBlockHash = headers[highestIndex].blockHash

proc peerSyncChainRequest(sp: SyncPeer, request: var BlocksRequest) =
  ## Choose `GetBlockHeaders` parameters when hunting or following the canonical
  ## chain of a peer.
  request = BlocksRequest(
    startBlock: HashOrNum(isHash: false),
    skip:       0,
    reverse:    false
  )

  if sp.syncMode == SyncLocked:
    # Stable and locked.  This is just checking for changes including reorgs.
    # `sp.bestBlockNumber` was recently the head of the peer's canonical
    # chain.  We must include this block number to detect when the canonical
    # chain gets shorter versus no change.
    request.startBlock.number =
        if sp.bestBlockNumber <= syncLockedQueryOverlap:
          # Every peer should send genesis for block 0, so don't ask for it.
          # `peerSyncChainEmptyReply` has logic to handle this reply as if it
          # was for block 0.  Aside from saving bytes, this is more robust if
          # some client doesn't do genesis reply correctly.
          1.toBlockNumber
        else:
          min(sp.bestBlockNumber - syncLockedQueryOverlap.toBlockNumber,
              high(BlockNumber) - (syncLockedQuerySize - 1).toBlockNumber)
    request.maxResults = syncLockedQuerySize
    return

  if sp.syncMode == SyncOnlyHash:
    # We only have the hash of the recent head of the peer's canonical chain.
    # Like `SyncLocked`, query more than one item to detect when the
    # canonical chain gets shorter, no change or longer.
    request.startBlock = HashOrNum(isHash: true, hash: sp.bestBlockHash)
    request.maxResults = syncLockedQuerySize
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
  # the gap to `startBlock` after `huntLow` and also before `huntHigh` are
  # proportional to the query step, where the query step is `huntStep`
  # exponentially expanding each round, or `maxStep` approximately evenly
  # distributed in the range.
  #
  # `huntLow+1` must not be used consistently as the start, even with a large
  # enough query step size, as that will sometimes take O(N) to converge in
  # both the exponential and quasi-binary searches.  (Ending at `huntHigh-1`
  # is fine if `syncHuntQuerySize > 1`.  This asymmetry is due to ascending
  # queries (see earlier comment), and non-empty truncated query reply being
  # proof of presence before the truncation point, but not proof of absence
  # after it.  A reply can be truncated just because the peer decides to.)
  #
  # The proportional gap requirement is why we divide by query size here,
  # instead of stretching to fit more strictly with `(range-1)/(size-1)`.

  const syncHuntFinalSize = max(2, syncHuntQuerySize)
  var maxStep: typeof(request.skip)

  let fullRangeClamped =
    if sp.huntHigh <= sp.huntLow: typeof(maxStep)(0)
    else: min(high(typeof(maxStep)).toBlockNumber,
              sp.huntHigh - sp.huntLow).truncate(typeof(maxStep)) - 1

  if fullRangeClamped >= syncHuntFinalSize: # `SyncHuntRangeFinal` condition.
    maxStep = if syncHuntQuerySize == 1:
                fullRangeClamped
              elif (syncHuntQuerySize and (syncHuntQuerySize-1)) == 0:
                fullRangeClamped shr fastLog2(syncHuntQuerySize)
              else:
                fullRangeClamped div syncHuntQuerySize
    doAssert syncHuntFinalSize >= syncHuntQuerySize
    doAssert maxStep >= 1 # Ensured by the above assertion.

  # Check for exponential search (expanding).  Iterate `huntStep`.  O(log N)
  # requires `startBlock` to be offset from `huntLow`/`huntHigh`.
  if sp.syncMode in {SyncHuntForward, SyncHuntBackward} and
     fullRangeClamped >= syncHuntFinalSize:
    let forward = sp.syncMode == SyncHuntForward
    let expandShift = if forward: syncHuntForwardExpandShift
                      else: syncHuntBackwardExpandShift
    # Switches to range search when this condition is no longer true.
    if sp.huntStep < maxStep shr expandShift:
      # The `if` above means the next line cannot overflow.
      sp.huntStep = if sp.huntStep > 0: sp.huntStep shl expandShift else: 1
      # Satisfy the O(log N) convergence conditions.
      request.startBlock.number =
        if forward: sp.huntLow + sp.huntStep.toBlockNumber
        else: sp.huntHigh - (sp.huntStep * syncHuntQuerySize).toBlockNumber
      request.maxResults = syncHuntQuerySize
      request.skip = sp.huntStep - 1
      return

  # For tracing/display.
  sp.huntStep = maxStep
  sp.syncMode = SyncHuntRange
  if maxStep > 0:
    # Quasi-binary search (converging in a range).  O(log N) requires
    # `startBlock` to satisfy the constraints described above, with the
    # proportionality from both ends of the range.  The optimal information
    # gathering position is tricky and doesn't make much difference, so don't
    # bother.  We'll centre the query in the range.
    var offset = fullRangeClamped - maxStep * (syncHuntQuerySize-1)
    # Rounding must bias towards end to ensure `offset >= 1` after this.
    offset -= offset shr 1
    request.startBlock.number = sp.huntLow + offset.toBlockNumber
    request.maxResults = syncHuntQuerySize
    request.skip = maxStep - 1
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
    let extra = syncHuntFinalSize - fullRangeClamped
    var before = (extra + 1) shr 1
    before = max(before + afterSoftMax, extra) - afterSoftMax
    before = min(before, beforeHardMax)
    # See `SyncLocked` case.
    request.startBlock.number =
      if sp.bestBlockNumber <= before.toBlockNumber: 1.toBlockNumber
      else: min(sp.bestBlockNumber - before.toBlockNumber,
                high(BlockNumber) - (syncHuntFinalSize - 1).toBlockNumber)
    request.maxResults = syncHuntFinalSize
    sp.syncMode = SyncHuntRangeFinal

proc peerSyncChainTrace(sp: SyncPeer) =
  ## To be called after `peerSyncChainRequest` has updated state.
  case sp.syncMode:
    of SyncLocked:
      trace "Sync: SyncLocked",
        best=sp.bestBlockNumber, bestHash=($sp.bestBlockHash)
    of SyncOnlyHash:
      trace "Sync: OnlyHash", bestHash=($sp.bestBlockHash)
    of SyncHuntForward:
      template highMax(n: BlockNumber): string =
        if n == high(BlockNumber): "max" else: $n
      trace "Sync: HuntForward",
        low=sp.huntLow, high=highMax(sp.huntHigh), step=sp.huntStep
    of SyncHuntBackward:
      trace "Sync: HuntBackward",
        low=sp.huntLow, high=sp.huntHigh, step=sp.huntStep
    of SyncHuntRange:
      trace "Sync: HuntRange",
        low=sp.huntLow, high=sp.huntHigh, step=sp.huntStep
    of SyncHuntRangeFinal:
      trace "Sync: HuntRangeFinal",
        low=sp.huntLow, high=sp.huntHigh, step=1

proc peerHuntCanonical*(sp: SyncPeer) {.async.} =
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

  # If we send multiple `GetBlockHeaders` requests, the replies can be out of
  # order, and prior to eth/66 there is no request-id.  We'll avoid this
  # problem by never sending overlapping `GetBlockHeaders` to the same peer.
  if sp.pendingGetBlockHeaders:
    trace ">| Blocked overlapping GetBlockHeaders (0x03)", peer=sp
    return
  sp.pendingGetBlockHeaders = true

  var request {.noinit.}: BlocksRequest
  sp.peerSyncChainRequest(request)

  if tracePackets:
    if request.startBlock.isHash:
      trace ">> Sending GetBlockHeaders/Hash (0x03)", peer=sp,
        `block`=request.startBlock, count=request.maxResults,
        step=traceStep(request)
    else:
      trace ">> Sending GetBlockHeaders/Num (0x03)", peer=sp,
        `block`=request.startBlock, count=request.maxResults,
        step=traceStep(request)

  inc sp.stats.ok.getBlockHeaders
  var reply: typeof await sp.peer.getBlockHeaders(request)
  try:
    reply = await sp.peer.getBlockHeaders(request)
  except CatchableError as e:
    if traceNetworkErrors:
      trace "<< Error waiting for reply to GetBlockHeaders (0x03)",
        peer=sp, error=e.msg
    inc sp.stats.major.networkErrors
    sp.stopped = true
    return

  if reply.isNone:
    if traceTimeouts:
      trace "<< Timeout waiting for reply to GetBlockHeaders (0x03)", peer=sp
    # TODO: Should disconnect?
    inc sp.stats.minor.timeoutBlockHeaders
    return

  let len = reply.get.headers.len
  if tracePackets:
    if len == 0:
      trace "<< Got EMPTY reply BlockHeaders (0x04)", peer=sp, count=len
    else:
      let first = reply.get.headers[0].blockNumber
      let last = reply.get.headers[len - 1].blockNumber
      trace "<< Got reply BlockHeaders (0x04)", peer=sp, count=len, first, last

  sp.pendingGetBlockHeaders = false

  if len > request.maxResults.int:
    if tracePacketErrors:
      trace "<< Protocol violation, excess headers in BlockHeaders (0x03)",
        peer=sp, maxResults=request.maxResults, got=len
    # TODO: Should disconnect.
    inc sp.stats.major.excessBlockHeaders
    return

  if len > 0:
    # TODO: Check this is not copying the `headers`.
    sp.peerSyncChainNonEmptyReply(request, reply.get.headers)
  else:
    sp.peerSyncChainEmptyReply(request)

# nim-eth
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[sets, options, random, hashes, sequtils],
  chronos, chronicles,
  ../sync/protocol_ethxx,
  eth/common/eth_types,
  eth/[p2p, p2p/private/p2p_types, p2p/rlpx, p2p/peer_pool]

{.push raises:[Defect].}

const
  minPeersToStartSync* = 2 # Wait for consensus of at least this
                           # number of peers before syncing

type
  SyncStatus* = enum
    syncSuccess
    syncNotEnoughPeers
    syncTimeOut

  BlockchainSyncDefect* = object of Defect
    ## Catch and relay exception

  WantedBlocksState = enum
    Initial,
    Requested,
    Received,
    Persisted

  WantedBlocks = object
    startIndex: BlockNumber
    numBlocks: uint
    state: WantedBlocksState
    headers: seq[BlockHeader]
    bodies: seq[BlockBody]

  SyncContext = ref object
    workQueue: seq[WantedBlocks]
    endBlockNumber: BlockNumber
    finalizedBlock: BlockNumber # Block which was downloaded and verified
    chain: AbstractChainDB
    peerPool: PeerPool
    trustedPeers: HashSet[Peer]
    hasOutOfOrderBlocks: bool

template catchException(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raise (ref CatchableError)(msg: e.msg)
  except Defect as e:
    raise (ref Defect)(msg: e.msg)
  except Exception as e:
    raise newException(
      BlockchainSyncDefect, info & "(): " & $e.name & " -- " & e.msg)

proc hash*(p: Peer): Hash = hash(cast[pointer](p))

proc endIndex(b: WantedBlocks): BlockNumber =
  result = b.startIndex
  result += (b.numBlocks - 1).toBlockNumber

proc availableWorkItem(ctx: SyncContext): int =
  var maxPendingBlock = ctx.finalizedBlock # the last downloaded & processed
  trace "queue len", length = ctx.workQueue.len
  result = -1
  for i in 0 .. ctx.workQueue.high:
    case ctx.workQueue[i].state
    of Initial:
      # When there is a work item at Initial state, immediatly use this one.
      # This usually means a previous work item that failed somewhere in the
      # process, and thus can be reused to work on.
      return i
    of Persisted:
      # In case of Persisted, we can reset this work item to a new one.
      result = i
      # No break here to give work items in Initial state priority and to
      # calculate endBlock.
    else:
      discard

    # Check all endBlocks of all workqueue items to decide on next range of
    # blocks to collect & process.
    let endBlock = ctx.workQueue[i].endIndex
    if endBlock > maxPendingBlock:
      maxPendingBlock = endBlock

  let nextRequestedBlock = maxPendingBlock + 1
  # If this next block doesn't exist yet according to any of our peers, don't
  # return a work item (and sync will be stopped).
  if nextRequestedBlock >= ctx.endBlockNumber:
    return -1

  # Increase queue when there are no free (Initial / Persisted) work items in
  # the queue. At start, queue will be empty.
  if result == -1:
    result = ctx.workQueue.len
    ctx.workQueue.setLen(result + 1)

  # Create new work item when queue was increased, reset when selected work item
  # is at Persisted state.
  var numBlocks = (ctx.endBlockNumber - nextRequestedBlock).truncate(int)
  if numBlocks > maxHeadersFetch:
    numBlocks = maxHeadersFetch
  ctx.workQueue[result] = WantedBlocks(startIndex: nextRequestedBlock, numBlocks: numBlocks.uint, state: Initial)

proc persistWorkItem(ctx: SyncContext, wi: var WantedBlocks): ValidationResult
    {.gcsafe, raises:[Defect,CatchableError].} =
  catchException("persistBlocks"):
    result = ctx.chain.persistBlocks(wi.headers, wi.bodies)
  case result
  of ValidationResult.OK:
    ctx.finalizedBlock = wi.endIndex
    wi.state = Persisted
  of ValidationResult.Error:
    wi.state = Initial
  # successful or not, we're done with these blocks
  wi.headers = @[]
  wi.bodies = @[]

proc persistPendingWorkItems(ctx: SyncContext): (int, ValidationResult)
    {.gcsafe, raises:[Defect,CatchableError].} =
  var nextStartIndex = ctx.finalizedBlock + 1
  var keepRunning = true
  var hasOutOfOrderBlocks = false
  trace "Looking for out of order blocks"
  while keepRunning:
    keepRunning = false
    hasOutOfOrderBlocks = false
    # Go over the full work queue and check for every work item if it is in
    # Received state and has the next blocks in line to be processed.
    for i in 0 ..< ctx.workQueue.len:
      let start = ctx.workQueue[i].startIndex
      # There should be at least 1 like this, namely the just received work item
      # that initiated this call.
      if ctx.workQueue[i].state == Received:
        if start == nextStartIndex:
          trace "Processing pending work item", number = start
          result = (i, ctx.persistWorkItem(ctx.workQueue[i]))
          # TODO: We can stop here on failure, but have to set
          # hasOutofORderBlocks. Is this always valid?
          nextStartIndex = ctx.finalizedBlock + 1
          keepRunning = true
          break
        else:
          hasOutOfOrderBlocks = true

  ctx.hasOutOfOrderBlocks = hasOutOfOrderBlocks

proc returnWorkItem(ctx: SyncContext, workItem: int): ValidationResult
    {.gcsafe, raises:[Defect,CatchableError].} =
  let wi = addr ctx.workQueue[workItem]
  let askedBlocks = wi.numBlocks.int
  let receivedBlocks = wi.headers.len
  let start = wi.startIndex

  if askedBlocks == receivedBlocks:
    trace "Work item complete",
      start,
      askedBlocks,
      receivedBlocks

    if wi.startIndex != ctx.finalizedBlock + 1:
      trace "Blocks out of order", start, final = ctx.finalizedBlock
      ctx.hasOutOfOrderBlocks = true

    if ctx.hasOutOfOrderBlocks:
      let (index, validation) = ctx.persistPendingWorkItems()
      # Only report an error if it was this peer's work item that failed
      if validation == ValidationResult.Error and index == workItem:
        result = ValidationResult.Error
      # TODO: What about failures on other peers' work items?
      # In that case the peer will probably get disconnected on future erroneous
      # work items, but before this occurs, several more blocks (that will fail)
      # might get downloaded from this peer. This will delay the sync and this
      # should be improved.
    else:
      trace "Processing work item", number = wi.startIndex
      # Validation result needs to be returned so that higher up can be decided
      # to disconnect from this peer in case of error.
      result = ctx.persistWorkItem(wi[])
  else:
    trace "Work item complete but we got fewer blocks than requested, so we're ditching the whole thing.",
      start,
      askedBlocks,
      receivedBlocks
    return ValidationResult.Error

proc newSyncContext(chain: AbstractChainDB, peerPool: PeerPool): SyncContext
    {.gcsafe, raises:[Defect,CatchableError].} =
  new result
  result.chain = chain
  result.peerPool = peerPool
  result.trustedPeers = initHashSet[Peer]()
  result.finalizedBlock = chain.getBestBlockHeader().blockNumber

proc handleLostPeer(ctx: SyncContext) =
  # TODO: ask the PeerPool for new connections and then call
  # `obtainBlocksFromPeer`
  discard

proc getBestBlockNumber(p: Peer): Future[BlockNumber] {.async.} =
  let request = BlocksRequest(
    startBlock: HashOrNum(isHash: true,
                          hash: p.state(eth).bestBlockHash),
    maxResults: 1,
    skip: 0,
    reverse: true)

  tracePacket ">> Sending eth.GetBlockHeaders (0x03)", peer=p,
    startBlock=request.startBlock.hash.toHex, max=request.maxResults
  let latestBlock = await p.getBlockHeaders(request)

  if latestBlock.isSome:
    if latestBlock.get.headers.len > 0:
      result = latestBlock.get.headers[0].blockNumber
    tracePacket "<< Got reply eth.BlockHeaders (0x04)", peer=p,
     count=latestBlock.get.headers.len,
     blockNumber=(if latestBlock.get.headers.len > 0: $result else: "missing")

proc obtainBlocksFromPeer(syncCtx: SyncContext, peer: Peer) {.async.} =
  # Update our best block number
  try:
    let bestBlockNumber = await peer.getBestBlockNumber()
    if bestBlockNumber > syncCtx.endBlockNumber:
      trace "New sync end block number", number = bestBlockNumber
      syncCtx.endBlockNumber = bestBlockNumber
  except TransportError:
    debug "Transport got closed during obtainBlocksFromPeer"
  except CatchableError as e:
    debug "Exception in getBestBlockNumber()", exc = e.name, err = e.msg
    # no need to exit here, because the context might still have blocks to fetch
    # from this peer

  while (let workItemIdx = syncCtx.availableWorkItem(); workItemIdx != -1 and
         peer.connectionState notin {Disconnecting, Disconnected}):
    template workItem: auto = syncCtx.workQueue[workItemIdx]
    workItem.state = Requested
    trace "Requesting block headers", start = workItem.startIndex,
      count = workItem.numBlocks, peer = peer.remote.node
    let request = BlocksRequest(
      startBlock: HashOrNum(isHash: false, number: workItem.startIndex),
      maxResults: workItem.numBlocks,
      skip: 0,
      reverse: false)

    var dataReceived = false
    try:
      tracePacket ">> Sending eth.GetBlockHeaders (0x03)", peer,
        startBlock=request.startBlock.number, max=request.maxResults
      let results = await peer.getBlockHeaders(request)
      if results.isSome:
        tracePacket "<< Got reply eth.BlockHeaders (0x04)", peer,
          count=results.get.headers.len
        shallowCopy(workItem.headers, results.get.headers)

        var bodies = newSeqOfCap[BlockBody](workItem.headers.len)
        var hashes = newSeqOfCap[KeccakHash](maxBodiesFetch)
        template fetchBodies() =
          tracePacket ">> Sending eth.GetBlockBodies (0x05)", peer,
            count=hashes.len
          let b = await peer.getBlockBodies(hashes)
          if b.isNone:
            raise newException(CatchableError, "Was not able to get the block bodies")
          let bodiesLen = b.get.blocks.len
          tracePacket "<< Got reply eth.BlockBodies (0x06)", peer,
            count=bodiesLen
          if bodiesLen == 0:
            raise newException(CatchableError, "Zero block bodies received for request")
          elif bodiesLen < hashes.len:
            hashes.delete(0, bodiesLen - 1)
          elif bodiesLen == hashes.len:
            hashes.setLen(0)
          else:
            raise newException(CatchableError, "Too many block bodies received for request")
          bodies.add(b.get.blocks)

        var nextIndex = workItem.startIndex
        for i in workItem.headers:
          if i.blockNumber != nextIndex:
            raise newException(CatchableError, "The block numbers are not in sequence. Not processing this workItem.")
          else:
            nextIndex = nextIndex + 1
          hashes.add(blockHash(i))
          if hashes.len == maxBodiesFetch:
            fetchBodies()

        while hashes.len != 0:
          fetchBodies()

        if bodies.len == workItem.headers.len:
          shallowCopy(workItem.bodies, bodies)
          dataReceived = true
        else:
          warn "Bodies len != headers.len", bodies = bodies.len, headers = workItem.headers.len
    except TransportError:
      debug "Transport got closed during obtainBlocksFromPeer"
    except CatchableError as e:
      # the success case sets `dataReceived`, so we can just fall back to the
      # failure path below. If we signal time-outs with exceptions such
      # failures will be easier to handle.
      debug "Exception in obtainBlocksFromPeer()", exc = e.name, err = e.msg

    var giveUpOnPeer = false

    if dataReceived:
      workItem.state = Received
      if syncCtx.returnWorkItem(workItemIdx) != ValidationResult.OK:
        giveUpOnPeer = true
    else:
      giveUpOnPeer = true

    if giveUpOnPeer:
      workItem.state = Initial
      try:
        await peer.disconnect(SubprotocolReason)
      except CatchableError:
        discard
      syncCtx.handleLostPeer()
      break

  trace "Finished obtaining blocks", peer

proc peersAgreeOnChain(a, b: Peer): Future[bool] {.async.} =
  # Returns true if one of the peers acknowledges existence of the best block
  # of another peer.
  var
    a = a
    b = b

  if a.state(eth).bestDifficulty < b.state(eth).bestDifficulty:
    swap(a, b)

  let request = BlocksRequest(
    startBlock: HashOrNum(isHash: true,
                          hash: b.state(eth).bestBlockHash),
    maxResults: 1,
    skip: 0,
    reverse: true)

  tracePacket ">> Sending eth.GetBlockHeaders (0x03)", peer=a,
    startBlock=request.startBlock.hash.toHex, max=request.maxResults
  let latestBlock = await a.getBlockHeaders(request)

  result = latestBlock.isSome and latestBlock.get.headers.len > 0
  if tracePackets and latestBlock.isSome:
    let blockNumber = if result: $latestBlock.get.headers[0].blockNumber
                      else: "missing"
    tracePacket "<< Got reply eth.BlockHeaders (0x04)", peer=a,
      count=latestBlock.get.headers.len, blockNumber

proc randomTrustedPeer(ctx: SyncContext): Peer =
  var k = rand(ctx.trustedPeers.len - 1)
  var i = 0
  for p in ctx.trustedPeers:
    result = p
    if i == k: return
    inc i

proc startSyncWithPeer(ctx: SyncContext, peer: Peer) {.async.} =
  trace "start sync", peer, trustedPeers = ctx.trustedPeers.len
  if ctx.trustedPeers.len >= minPeersToStartSync:
    # We have enough trusted peers. Validate new peer against trusted
    if await peersAgreeOnChain(peer, ctx.randomTrustedPeer()):
      ctx.trustedPeers.incl(peer)
      asyncCheck ctx.obtainBlocksFromPeer(peer)
  elif ctx.trustedPeers.len == 0:
    # Assume the peer is trusted, but don't start sync until we reevaluate
    # it with more peers
    trace "Assume trusted peer", peer
    ctx.trustedPeers.incl(peer)
  else:
    # At this point we have some "trusted" candidates, but they are not
    # "trusted" enough. We evaluate `peer` against all other candidates.
    # If one of the candidates disagrees, we swap it for `peer`. If all
    # candidates agree, we add `peer` to trusted set. The peers in the set
    # will become "fully trusted" (and sync will start) when the set is big
    # enough
    var
      agreeScore = 0
      disagreedPeer: Peer

    for tp in ctx.trustedPeers:
      if await peersAgreeOnChain(peer, tp):
        inc agreeScore
      else:
        disagreedPeer = tp

    let disagreeScore = ctx.trustedPeers.len - agreeScore

    if agreeScore == ctx.trustedPeers.len:
      ctx.trustedPeers.incl(peer) # The best possible outcome
    elif disagreeScore == 1:
      trace "Peer is no longer trusted for sync", peer
      ctx.trustedPeers.excl(disagreedPeer)
      ctx.trustedPeers.incl(peer)
    else:
      trace "Peer not trusted for sync", peer

    if ctx.trustedPeers.len == minPeersToStartSync:
      for p in ctx.trustedPeers:
        asyncCheck ctx.obtainBlocksFromPeer(p)


proc onPeerConnected(ctx: SyncContext, peer: Peer) =
  trace "New candidate for sync", peer
  try:
    let f = ctx.startSyncWithPeer(peer)
    f.callback = proc(data: pointer) {.gcsafe.} =
      if f.failed:
        if f.error of TransportError:
          debug "Transport got closed during startSyncWithPeer"
        else:
          error "startSyncWithPeer failed", msg = f.readError.msg, peer
  except TransportError:
    debug "Transport got closed during startSyncWithPeer"
  except CatchableError as e:
    debug "Exception in startSyncWithPeer()", exc = e.name, err = e.msg


proc onPeerDisconnected(ctx: SyncContext, p: Peer) =
  trace "peer disconnected ", peer = p
  ctx.trustedPeers.excl(p)

proc startSync(ctx: SyncContext) =
  var po: PeerObserver
  po.onPeerConnected = proc(p: Peer) {.gcsafe.} =
    ctx.onPeerConnected(p)

  po.onPeerDisconnected = proc(p: Peer) {.gcsafe.} =
    ctx.onPeerDisconnected(p)

  po.setProtocol eth
  ctx.peerPool.addObserver(ctx, po)

proc findBestPeer(node: EthereumNode): (Peer, DifficultyInt) =
  var
    bestBlockDifficulty: DifficultyInt = 0.stuint(256)
    bestPeer: Peer = nil

  for peer in node.peers(eth):
    let peerEthState = peer.state(eth)
    if peerEthState.initialized:
      if peerEthState.bestDifficulty > bestBlockDifficulty:
        bestBlockDifficulty = peerEthState.bestDifficulty
        bestPeer = peer

  result = (bestPeer, bestBlockDifficulty)

proc fastBlockchainSync*(node: EthereumNode): Future[SyncStatus] {.async.} =
  ## Code for the fast blockchain sync procedure:
  ## https://github.com/ethereum/wiki/wiki/Parallel-Block-Downloads
  ## https://github.com/ethereum/go-ethereum/pull/1889
  # TODO: This needs a better interface. Consider removing this function and
  # exposing SyncCtx
  var syncCtx = newSyncContext(node.chain, node.peerPool)
  syncCtx.startSync()


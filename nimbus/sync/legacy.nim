# nim-eth
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[sets, options, random,
    hashes, sequtils, math, tables, times],
  chronicles,
  chronos,
  eth/p2p,
  eth/p2p/[private/p2p_types, peer_pool],
  stew/byteutils,
  "."/[protocol, types],
  ../core/[chain, clique/clique_sealer, eip4844, gaslimit, withdrawals],
  ../core/pow/difficulty,
  ../constants,
  ../utils/utils,
  ../common/common

{.push raises:[].}

logScope:
  topics = "legacy-sync"

const
  minPeersToStartSync* = 2 # Wait for consensus of at least this
                           # number of peers before syncing
  CleanupInterval = initDuration(minutes = 20)

type
  #SyncStatus = enum
  #  syncSuccess
  #  syncNotEnoughPeers
  #  syncTimeOut

  HashToTime = TableRef[Hash256, Time]

  BlockchainSyncDefect* = object of Defect
    ## Catch and relay exception

  WantedBlocksState = enum
    Initial,
    Requested,
    Received,
    Persisted

  WantedBlocks = object
    isHash: bool
    hash: Hash256
    startIndex: BlockNumber
    numBlocks: uint
    state: WantedBlocksState
    headers: seq[BlockHeader]
    bodies: seq[BlockBody]

  LegacySyncRef* = ref object
    workQueue: seq[WantedBlocks]
    chain: ChainRef
    peerPool: PeerPool
    trustedPeers: HashSet[Peer]
    hasOutOfOrderBlocks: bool
    busyPeers: HashSet[Peer]
    knownByPeer: Table[Peer, HashToTime]
    lastCleanup: Time


# ------------------------------------------------------------------------------
# Private functions: sync progress
# ------------------------------------------------------------------------------

template endBlockNumber(ctx: LegacySyncRef): BlockNumber =
  ctx.chain.com.syncHighest

template `endBlockNumber=`(ctx: LegacySyncRef, number: BlockNumber) =
  ctx.chain.com.syncHighest = number

# Block which was downloaded and verified
template finalizedBlock(ctx: LegacySyncRef): BlockNumber =
  ctx.chain.com.syncCurrent

template `finalizedBlock=`(ctx: LegacySyncRef, number: BlockNumber) =
  ctx.chain.com.syncCurrent = number

# ------------------------------------------------------------------------------
# Private functions: peers related functions
# ------------------------------------------------------------------------------

proc hash*(p: Peer): Hash = hash(cast[pointer](p))

proc cleanupKnownByPeer(ctx: LegacySyncRef) =
  let now = getTime()
  var tmp = initHashSet[Hash256]()
  for _, map in ctx.knownByPeer:
    for hash, time in map:
      if time - now >= CleanupInterval:
        tmp.incl hash
    for hash in tmp:
      map.del(hash)
    tmp.clear()

  var tmpPeer = initHashSet[Peer]()
  for peer, map in ctx.knownByPeer:
    if map.len == 0:
      tmpPeer.incl peer

  for peer in tmpPeer:
    ctx.knownByPeer.del peer

  ctx.lastCleanup = now

proc addToKnownByPeer(ctx: LegacySyncRef,
                      blockHash: Hash256,
                      peer: Peer): bool =

  var map: HashToTime
  ctx.knownByPeer.withValue(peer, val) do:
    map = val[]
    result = true
  do:
    map = newTable[Hash256, Time]()
    ctx.knownByPeer[peer] = map
    result = false

  map[blockHash] = getTime()

proc getPeers(ctx: LegacySyncRef, thisPeer: Peer): seq[Peer] =
  # do not send back block/blockhash to thisPeer
  for peer in peers(ctx.peerPool):
    if peer != thisPeer:
      result.add peer

proc handleLostPeer(ctx: LegacySyncRef) =
  # TODO: ask the PeerPool for new connections and then call
  # `obtainBlocksFromPeer`
  discard

# ------------------------------------------------------------------------------
# Private functions: validators
# ------------------------------------------------------------------------------

proc validateDifficulty(ctx: LegacySyncRef,
                        header, parentHeader: BlockHeader,
                        consensusType: ConsensusType): bool =
  try:
    let com = ctx.chain.com

    case consensusType
    of ConsensusType.POA:
      let rc = ctx.chain.clique.calcDifficulty(parentHeader)
      if rc.isErr:
        return false
      if header.difficulty < rc.get():
        trace "provided header difficulty is too low",
          expect=rc.get(), get=header.difficulty
        return false

    of ConsensusType.POW:
      let calcDiffc = com.calcDifficulty(header.timestamp, parentHeader)
      if header.difficulty < calcDiffc:
        trace "provided header difficulty is too low",
          expect=calcDiffc, get=header.difficulty
        return false

    of ConsensusType.POS:
      if header.difficulty != 0.u256:
        trace "invalid difficulty",
          expect=0, get=header.difficulty
        return false

    return true
  except CatchableError as e:
    error "Exception in FastSync.validateDifficulty()",
      exc = e.name, err = e.msg
    return false

proc validateHeader(ctx: LegacySyncRef, header: BlockHeader,
                    body: BlockBody,
                    height = none(BlockNumber)): bool
                    {.raises: [CatchableError].} =
  if header.parentHash == GENESIS_PARENT_HASH:
    return true

  let
    db  = ctx.chain.db
    com = ctx.chain.com

  var parentHeader: BlockHeader
  if not db.getBlockHeader(header.parentHash, parentHeader):
    error "can't get parentHeader",
      hash=header.parentHash, number=header.blockNumber
    return false

  if header.blockNumber != parentHeader.blockNumber + 1.toBlockNumber:
    trace "invalid block number",
      expect=parentHeader.blockNumber + 1.toBlockNumber,
      get=header.blockNumber
    return false

  if header.timestamp <= parentHeader.timestamp:
    trace "invalid timestamp",
      parent=parentHeader.timestamp,
      header=header.timestamp
    return false

  let consensusType = com.consensus(header)
  if not ctx.validateDifficulty(header, parentHeader, consensusType):
    return false

  if consensusType == ConsensusType.POA:
    let period = initDuration(seconds = com.cliquePeriod)
    # Timestamp diff between blocks is lower than PERIOD (clique)
    if parentHeader.timestamp + period > header.timestamp:
      trace "invalid timestamp diff (lower than period)",
        parent=parentHeader.timestamp,
        header=header.timestamp,
        period
      return false

  var res = com.validateGasLimitOrBaseFee(header, parentHeader)
  if res.isErr:
    trace "validate gaslimit error",
      msg=res.error
    return false

  if height.isSome:
    let dif = height.get() - parentHeader.blockNumber
    if not (dif < 8.toBlockNumber and dif > 1.toBlockNumber):
      trace "uncle block has a parent that is too old or too young",
        dif=dif,
        height=height.get(),
        parentNumber=parentHeader.blockNumber
      return false

  res = com.validateWithdrawals(header, body)
  if res.isErr:
    trace "validate withdrawals error",
      msg=res.error
    return false

  res = com.validateEip4844Header(header, parentHeader, body.transactions)
  if res.isErr:
    trace "validate eip4844 error",
      msg=res.error
    return false

  return true

# ------------------------------------------------------------------------------
# Private functions: sync worker
# ------------------------------------------------------------------------------

proc broadcastBlockHash(ctx: LegacySyncRef, hashes: seq[NewBlockHashesAnnounce], peers: seq[Peer]) {.async.} =
  try:

    var bha = newSeqOfCap[NewBlockHashesAnnounce](hashes.len)
    for peer in peers:
      for val in hashes:
        let alreadyKnownByPeer = ctx.addToKnownByPeer(val.hash, peer)
        if not alreadyKnownByPeer:
          bha.add val
      if bha.len > 0:
        trace trEthSendNewBlockHashes, numHashes=bha.len, peer
        await peer.newBlockHashes(bha)
        bha.setLen(0)

  except TransportError:
    debug "Transport got closed during broadcastBlockHash"
  except CatchableError as e:
    debug "Exception in broadcastBlockHash", exc = e.name, err = e.msg

proc broadcastBlock(ctx: LegacySyncRef, blk: EthBlock, peers: seq[Peer]) {.async.} =
  try:

    let
      db        = ctx.chain.db
      blockHash = blk.header.blockHash
      td        = db.getScore(blk.header.parentHash) +
                    blk.header.difficulty

    for peer in peers:
      let alreadyKnownByPeer = ctx.addToKnownByPeer(blockHash, peer)
      if not alreadyKnownByPeer:
        trace trEthSendNewBlock,
          number=blk.header.blockNumber, td=td,
          hash=short(blockHash), peer
        await peer.newBlock(blk, td)

  except TransportError:
    debug "Transport got closed during broadcastBlock"
  except CatchableError as e:
    debug "Exception in broadcastBlock", exc = e.name, err = e.msg

proc broadcastBlockHash(ctx: LegacySyncRef, blk: EthBlock, peers: seq[Peer]) {.async.} =
  try:

    let bha = NewBlockHashesAnnounce(
      number: blk.header.blockNumber,
      hash: blk.header.blockHash
    )

    for peer in peers:
      let alreadyKnownByPeer = ctx.addToKnownByPeer(bha.hash, peer)
      if not alreadyKnownByPeer:
        trace trEthSendNewBlockHashes,
          number=bha.number, hash=short(bha.hash), peer
        await peer.newBlockHashes([bha])

  except TransportError:
    debug "Transport got closed during broadcastBlockHash"
  except CatchableError as e:
    debug "Exception in broadcastBlockHash", exc = e.name, err = e.msg

proc sendBlockOrHash(ctx: LegacySyncRef, peer: Peer) {.async.} =
  # because peer TD is lower than us,
  # it become our recipient of block and block hashes
  # instead of we download from it

  try:
    let
      db = ctx.chain.db
      peerBlockHash = peer.state(eth).bestBlockHash

    var peerBlockHeader: BlockHeader
    if not db.getBlockHeader(peerBlockHash, peerBlockHeader):
      error "can't get block header", hash=short(peerBlockHash)
      return

    let
      dist = (ctx.finalizedBlock - peerBlockHeader.blockNumber).truncate(int)
      start = peerBlockHeader.blockNumber + 1.toBlockNumber

    if dist == 1:
      # only one block apart, send NewBlock
      let number = ctx.finalizedBlock
      var header: BlockHeader
      var body: BlockBody
      if not db.getBlockHeader(number, header):
        error "can't get block header", number=number
        return

      let blockHash = header.blockHash
      if not db.getBlockBody(blockHash, body):
        error "can't get block body", number=number
        return

      let
        ourTD  = db.getScore(blockHash)
        newBlock = EthBlock(
          header: header,
          txs: body.transactions,
          uncles: body.uncles)

      trace "send newBlock",
        number = header.blockNumber,
        hash = short(header.blockHash),
        td = ourTD, peer
      await peer.newBlock(newBlock, ourTD)
      return

    if dist > maxHeadersFetch:
      # distance is too far, ignore this peer
      return

    # send hashes in batch
    var
      hash: Hash256
      number = 0
      hashes = newSeqOfCap[NewBlockHashesAnnounce](maxHeadersFetch)

    while number < dist:
      let blockNumber = start + number.toBlockNumber
      if not db.getBlockHash(blockNumber, hash):
        error "failed to get block hash", number=blockNumber
        return

      hashes.add(NewBlockHashesAnnounce(
        number: blockNumber,
        hash: hash))

      if hashes.len == maxHeadersFetch:
        trace "send newBlockHashes(batch)", numHashes=hashes.len, peer
        await peer.newBlockHashes(hashes)
        hashes.setLen(0)
      inc number

    # send the rest of hashes if available
    if hashes.len > 0:
      trace "send newBlockHashes(remaining)", numHashes=hashes.len, peer
      await peer.newBlockHashes(hashes)

  except TransportError:
    debug "Transport got closed during obtainBlocksFromPeer"
  except CatchableError as e:
    debug "Exception in getBestBlockNumber()", exc = e.name, err = e.msg
    # no need to exit here, because the context might still have blocks to fetch
    # from this peer
    discard e

proc endIndex(b: WantedBlocks): BlockNumber =
  result = b.startIndex
  result += (b.numBlocks - 1).toBlockNumber

proc availableWorkItem(ctx: LegacySyncRef): int =
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
  if nextRequestedBlock > ctx.endBlockNumber:
    return -1

  # Increase queue when there are no free (Initial / Persisted) work items in
  # the queue. At start, queue will be empty.
  if result == -1:
    result = ctx.workQueue.len
    ctx.workQueue.setLen(result + 1)

  # Create new work item when queue was increased, reset when selected work item
  # is at Persisted state.
  var numBlocks = (ctx.endBlockNumber - nextRequestedBlock).truncate(int) + 1

  if numBlocks > maxHeadersFetch:
    numBlocks = maxHeadersFetch
  ctx.workQueue[result] = WantedBlocks(
    startIndex: nextRequestedBlock,
    numBlocks : numBlocks.uint,
    state     : Initial,
    isHash    : false)

proc appendWorkItem(ctx: LegacySyncRef, hash: Hash256,
                    startIndex: BlockNumber, numBlocks: uint) =
  for i in 0 .. ctx.workQueue.high:
    if ctx.workQueue[i].state == Persisted:
      ctx.workQueue[i] = WantedBlocks(
        isHash    : true,
        hash      : hash,
        startIndex: startIndex,
        numBlocks : numBlocks,
        state     : Initial)
      return

  let i = ctx.workQueue.len
  ctx.workQueue.setLen(i + 1)
  ctx.workQueue[i] = WantedBlocks(
    isHash    : true,
    hash      : hash,
    startIndex: startIndex,
    numBlocks : numBlocks,
    state     : Initial)

proc persistWorkItem(ctx: LegacySyncRef, wi: var WantedBlocks): ValidationResult =
  try:
    result = ctx.chain.persistBlocks(wi.headers, wi.bodies)
  except CatchableError as e:
    error "storing persistent blocks failed", error = $e.name, msg = e.msg
    result = ValidationResult.Error
  case result
  of ValidationResult.OK:
    ctx.finalizedBlock = wi.endIndex
    wi.state = Persisted
  of ValidationResult.Error:
    wi.state = Initial
  # successful or not, we're done with these blocks
  wi.headers = @[]
  wi.bodies = @[]

proc persistPendingWorkItems(ctx: LegacySyncRef): (int, ValidationResult) =
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

proc returnWorkItem(ctx: LegacySyncRef, workItem: int): ValidationResult =
  let wi = addr ctx.workQueue[workItem]
  let askedBlocks = wi.numBlocks.int
  let receivedBlocks = wi.headers.len
  let start {.used.} = wi.startIndex

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

proc getBestBlockNumber(p: Peer): Future[BlockNumber] {.async.} =
  let request = BlocksRequest(
    startBlock: HashOrNum(isHash: true,
                          hash: p.state(eth).bestBlockHash),
    maxResults: 1,
    skip: 0,
    reverse: true)

  trace trEthSendSendingGetBlockHeaders, peer=p,
    startBlock=request.startBlock.hash.toHex, max=request.maxResults
  let latestBlock = await p.getBlockHeaders(request)

  if latestBlock.isSome:
    if latestBlock.get.headers.len > 0:
      result = latestBlock.get.headers[0].blockNumber
    trace trEthRecvReceivedBlockHeaders, peer=p,
      count=latestBlock.get.headers.len,
      blockNumber=(if latestBlock.get.headers.len > 0: $result else: "missing")

proc toRequest(workItem: WantedBlocks): BlocksRequest =
  if workItem.isHash:
    BlocksRequest(
      startBlock: HashOrNum(isHash: true, hash: workItem.hash),
      maxResults: workItem.numBlocks,
      skip: 0,
      reverse: false)
  else:
    BlocksRequest(
      startBlock: HashOrNum(isHash: false, number: workItem.startIndex),
      maxResults: workItem.numBlocks,
      skip: 0,
      reverse: false)

type
  BodyHash = object
    txRoot: Hash256
    uncleHash: Hash256

proc hash*(x: BodyHash): Hash =
  var h: Hash = 0
  h = h !& hash(x.txRoot.data)
  h = h !& hash(x.uncleHash.data)
  result = !$h

proc fetchBodies(ctx: LegacySyncRef, peer: Peer,
                 workItemIdx: int, reqBodies: seq[bool]): Future[bool] {.async.} =
  template workItem: auto = ctx.workQueue[workItemIdx]
  var bodies = newSeqOfCap[BlockBody](workItem.headers.len)
  var hashes = newSeqOfCap[KeccakHash](maxBodiesFetch)

  doAssert(reqBodies.len == workItem.headers.len)

  template fetchBodies() =
    trace trEthSendSendingGetBlockBodies, peer,
      hashes=hashes.len
    let b = await peer.getBlockBodies(hashes)
    if b.isNone:
      raise newException(CatchableError, "Was not able to get the block bodies")
    let bodiesLen = b.get.blocks.len
    trace trEthRecvReceivedBlockBodies, peer,
      count=bodiesLen, requested=hashes.len
    if bodiesLen == 0:
      raise newException(CatchableError, "Zero block bodies received for request")
    elif bodiesLen < hashes.len:
      hashes.delete(0, bodiesLen - 1)
    elif bodiesLen == hashes.len:
      hashes.setLen(0)
    else:
      raise newException(CatchableError, "Too many block bodies received for request")
    bodies.add(b.get.blocks)

  var numRequest = 0
  for i, h in workItem.headers:
    if reqBodies[i]:
      hashes.add(h.blockHash)
      inc numRequest

    if hashes.len == maxBodiesFetch:
      fetchBodies()

  while hashes.len != 0:
    fetchBodies()

  workItem.bodies = newSeqOfCap[BlockBody](workItem.headers.len)
  var bodyHashes = initTable[BodyHash, int]()
  for z, body in bodies:
    let bodyHash = BodyHash(
      txRoot: calcTxRoot(body.transactions),
      uncleHash: rlpHash(body.uncles))
    bodyHashes[bodyHash] = z

  for i, req in reqBodies:
    if req:
      let bodyHash = BodyHash(
        txRoot: workItem.headers[i].txRoot,
        uncleHash: workItem.headers[i].ommersHash)
      let z = bodyHashes.getOrDefault(bodyHash, -1)
      if z == -1:
        error "header missing it's body",
          number=workItem.headers[i].blockNumber,
          hash=workItem.headers[i].blockHash.short
        return false
      workItem.bodies.add bodies[z]
    else:
      workItem.bodies.add BlockBody()

  return true

proc obtainBlocksFromPeer(ctx: LegacySyncRef, peer: Peer) {.async.} =
  # Update our best block number
  try:
    if ctx.endBlockNumber <= ctx.finalizedBlock:
      # endBlockNumber need update
      let bestBlockNumber = await peer.getBestBlockNumber()
      if bestBlockNumber > ctx.endBlockNumber:
        trace "New sync end block number", number = bestBlockNumber
        ctx.endBlockNumber = bestBlockNumber
  except TransportError:
    debug "Transport got closed during obtainBlocksFromPeer"
  except CatchableError as e:
    debug "Exception in getBestBlockNumber()", exc = e.name, err = e.msg
    # no need to exit here, because the context might still have blocks to fetch
    # from this peer
    discard e

  while (let workItemIdx = ctx.availableWorkItem(); workItemIdx != -1 and
         peer.connectionState notin {Disconnecting, Disconnected}):
    template workItem: auto = ctx.workQueue[workItemIdx]
    workItem.state = Requested
    trace "Requesting block headers", start = workItem.startIndex,
      count = workItem.numBlocks, peer = peer.remote.node
    let request = toRequest(workItem)
    var dataReceived = true
    try:
      trace trEthSendSendingGetBlockHeaders, peer,
        startBlock=request.startBlock.number, max=request.maxResults,
        step=traceStep(request)
      let results = await peer.getBlockHeaders(request)
      if results.isSome:
        trace trEthRecvReceivedBlockHeaders, peer,
          count=results.get.headers.len, requested=request.maxResults
        shallowCopy(workItem.headers, results.get.headers)

        var
          reqBodies  = newSeqOfCap[bool](workItem.headers.len)
          numRequest = 0
          nextIndex  = workItem.startIndex

        # skip requesting empty bodies
        for h in workItem.headers:
          if h.blockNumber != nextIndex:
            raise newException(CatchableError,
              "The block numbers are not in sequence. Not processing this workItem.")

          nextIndex = nextIndex + 1
          let req = h.txRoot != EMPTY_ROOT_HASH or
                    h.ommersHash != EMPTY_UNCLE_HASH
          reqBodies.add(req)
          if req: inc numRequest

        if numRequest > 0:
          dataReceived = dataReceived and
            await ctx.fetchBodies(peer, workItemIdx, reqBodies)
        else:
          # all bodies are empty
          workItem.bodies.setLen(workItem.headers.len)

        let peers = ctx.getPeers(peer)
        if peers.len > 0:
          var hashes = newSeqOfCap[NewBlockHashesAnnounce](workItem.headers.len)
          for h in workItem.headers:
            hashes.add NewBlockHashesAnnounce(
              hash: h.blockHash,
              number: h.blockNumber)
          trace "broadcast block hashes", numPeers=peers.len, numHashes=hashes.len
          await ctx.broadcastBlockHash(hashes, peers)

        # fetchBodies can fail
        dataReceived = dataReceived and true

      else:
        dataReceived = false
    except TransportError:
      debug "Transport got closed during obtainBlocksFromPeer",
        peer
    except CatchableError as e:
      # the success case sets `dataReceived`, so we can just fall back to the
      # failure path below. If we signal time-outs with exceptions such
      # failures will be easier to handle.
      debug "Exception in obtainBlocksFromPeer()",
        exc = e.name, err = e.msg, peer

    var giveUpOnPeer = false
    if dataReceived:
      trace "Finished obtaining blocks", peer, numBlocks=workItem.headers.len

      workItem.state = Received
      let res = ctx.returnWorkItem(workItemIdx)
      if res != ValidationResult.OK:
        trace  "validation error"
        giveUpOnPeer = true
    else:
      giveUpOnPeer = true

    if giveUpOnPeer:
      workItem.state = Initial
      try:
        await peer.disconnect(SubprotocolReason)
      except CatchableError:
        discard
      ctx.handleLostPeer()
      break

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

  trace trEthSendSendingGetBlockHeaders, peer=a,
    startBlock=request.startBlock.hash.toHex, max=request.maxResults
  var latestBlock: Option[blockHeadersObj]
  try:
    latestBlock = await a.getBlockHeaders(request)
  except TransportError:
    debug "Transport got closed during peersAgreeOnChain"
    return

  result = latestBlock.isSome and latestBlock.get.headers.len > 0
  if latestBlock.isSome:
    let blockNumber {.used.} = if result: $latestBlock.get.headers[0].blockNumber
                               else: "missing"
    trace trEthRecvReceivedBlockHeaders, peer=a,
      count=latestBlock.get.headers.len, blockNumber

proc randomTrustedPeer(ctx: LegacySyncRef): Peer =
  var k = rand(ctx.trustedPeers.len - 1)
  var i = 0
  for p in ctx.trustedPeers:
    result = p
    if i == k: return
    inc i

proc startSyncWithPeerImpl(ctx: LegacySyncRef, peer: Peer) {.async.} =
  trace "Start sync", peer, trustedPeers = ctx.trustedPeers.len
  if ctx.trustedPeers.len >= minPeersToStartSync:
    # We have enough trusted peers. Validate new peer against trusted
    if await peersAgreeOnChain(peer, ctx.randomTrustedPeer()):
      ctx.trustedPeers.incl(peer)
      asyncSpawn ctx.obtainBlocksFromPeer(peer)
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
        asyncSpawn ctx.obtainBlocksFromPeer(p)

proc startSyncWithPeer(ctx: LegacySyncRef, peer: Peer) =
  try:
    let
      db     = ctx.chain.db
      header = db.getBlockHeader(ctx.finalizedBlock)
      ourTD  = db.getScore(header.blockHash)
      peerTD = peer.state(eth).bestDifficulty

    if peerTD <= ourTD:
      # do nothing if peer have same height
      if peerTD < ourTD:
        trace "Peer have lower TD, become recipient",
          peer, ourTD, peerTD
        asyncSpawn ctx.sendBlockOrHash(peer)
      return

    ctx.busyPeers.incl(peer)
    let f = ctx.startSyncWithPeerImpl(peer)
    f.callback = proc(data: pointer) {.gcsafe.} =
      if f.failed:
        if f.error of TransportError:
          debug "Transport got closed during startSyncWithPeer"
        else:
          error "startSyncWithPeer failed", msg = f.readError.msg, peer
      ctx.busyPeers.excl(peer)
    asyncSpawn f

  except TransportError:
    debug "Transport got closed during startSyncWithPeer"
  except CatchableError as e:
    debug "Exception in startSyncWithPeer()", exc = e.name, err = e.msg

proc startObtainBlocks(ctx: LegacySyncRef, peer: Peer) =
  # simpler version of startSyncWithPeer
  try:

    ctx.busyPeers.incl(peer)
    let f = ctx.obtainBlocksFromPeer(peer)
    f.callback = proc(data: pointer) {.gcsafe.} =
      if f.failed:
        if f.error of TransportError:
          debug "Transport got closed during startObtainBlocks"
        else:
          error "startObtainBlocks failed", msg = f.readError.msg, peer
      ctx.busyPeers.excl(peer)
    asyncSpawn f

  except TransportError:
    debug "Transport got closed during startObtainBlocks"
  except CatchableError as e:
    debug "Exception in startObtainBlocks()", exc = e.name, err = e.msg

proc onPeerConnected(ctx: LegacySyncRef, peer: Peer) =
  trace "New candidate for sync", peer
  ctx.startSyncWithPeer(peer)

proc onPeerDisconnected(ctx: LegacySyncRef, p: Peer) =
  trace "peer disconnected ", peer = p
  ctx.trustedPeers.excl(p)
  ctx.busyPeers.excl(p)
  ctx.knownByPeer.del(p)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(T: type LegacySyncRef; ethNode: EthereumNode; chain: ChainRef): T
    {.gcsafe, raises:[CatchableError].} =
  result = LegacySyncRef(
    # workQueue:           n/a
    # endBlockNumber:      n/a
    # hasOutOfOrderBlocks: n/a
    chain:          chain,
    peerPool:       ethNode.peerPool,
    trustedPeers:   initHashSet[Peer]())

  # finalizedBlock
  chain.com.syncCurrent = chain.db.getCanonicalHead().blockNumber

proc start*(ctx: LegacySyncRef) =
  ## Code for the fast blockchain sync procedure:
  ##   <https://github.com/ethereum/wiki/wiki/Parallel-Block-Downloads>_
  ##   <https://github.com/ethereum/go-ethereum/pull/1889__

  try:
    var blockHash: Hash256
    let
      db  = ctx.chain.db
      com = ctx.chain.com

    if not db.getBlockHash(ctx.finalizedBlock, blockHash):
      debug "FastSync.start: Failed to get blockHash",
        number=ctx.finalizedBlock
      return

    if com.consensus == ConsensusType.POS:
      debug "Fast sync is disabled after POS merge"
      return

    ctx.chain.com.syncStart = ctx.finalizedBlock
    info "Fast Sync: start sync from",
      number=ctx.chain.com.syncStart,
      hash=blockHash

  except CatchableError as e:
    debug "Exception in FastSync.start()",
      exc = e.name, err = e.msg

  var po = PeerObserver(
    onPeerConnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerConnected(p),
    onPeerDisconnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerDisconnected(p))
  po.setProtocol eth
  ctx.peerPool.addObserver(ctx, po)

# ------------------------------------------------------------------------------
# Public procs: eth wire protocol handlers
# ------------------------------------------------------------------------------

proc handleNewBlockHashes(ctx: LegacySyncRef,
                          peer: Peer,
                          hashes: openArray[NewBlockHashesAnnounce]) =

  trace trEthRecvNewBlockHashes,
    numHash=hashes.len

  if hashes.len == 0:
    return

  var number = hashes[0].number
  if hashes.len > 1:
    for i in 1..<hashes.len:
      let val = hashes[i]
      if val.number != number + 1.toBlockNumber:
        error "Found a gap in block hashes"
        return
      number = val.number

  number = hashes[^1].number
  if number <= ctx.endBlockNumber:
    trace "Will not set new synctarget",
      newSyncHeight=number,
      endBlockNumber=ctx.endBlockNumber,
      peer
    return

  # don't send back hashes to this peer
  for val in hashes:
    discard ctx.addToKnownByPeer(val.hash, peer)

  # set new sync target, + 1'u means including last block
  let numBlocks = (number - hashes[0].number).truncate(uint) + 1'u
  ctx.appendWorkItem(hashes[0].hash, hashes[0].number, numBlocks)
  ctx.endBlockNumber = number
  trace "New sync target height", number

  if ctx.busyPeers.len > 0:
    # do nothing. busy peers will keep syncing
    # until new sync target reached
    trace "sync using busyPeers",
      len=ctx.busyPeers.len
    return

  if ctx.trustedPeers.len == 0:
    trace "sync with this peer"
    ctx.startObtainBlocks(peer)
  else:
    trace "sync with random peer"
    let peer = ctx.randomTrustedPeer()
    ctx.startSyncWithPeer(peer)

proc handleNewBlock(ctx: LegacySyncRef,
                    peer: Peer,
                    blk: EthBlock,
                    totalDifficulty: DifficultyInt) {.
                      gcsafe, raises: [CatchableError].} =

  trace trEthRecvNewBlock,
    number=blk.header.blockNumber,
    hash=short(blk.header.blockHash)

  if ctx.lastCleanup - getTime() > CleanupInterval:
    ctx.cleanupKnownByPeer()

  # Don't send NEW_BLOCK announcement to peer that sent original new block message
  discard ctx.addToKnownByPeer(blk.header.blockHash, peer)

  if blk.header.blockNumber > ctx.finalizedBlock + 1.toBlockNumber:
    # If the block number exceeds one past our height we cannot validate it
    trace "NewBlock got block past our height",
      number=blk.header.blockNumber
    return

  let body = BlockBody(
    transactions: blk.txs,
    uncles: blk.uncles,
    withdrawals: blk.withdrawals
  )

  if not ctx.validateHeader(blk.header, body):
    error "invalid header from peer",
      peer, hash=short(blk.header.blockHash)
    return

  # Send NEW_BLOCK to square root of total number of peers in pool
  # https://github.com/ethereum/devp2p/blob/master/caps/eth.md#block-propagation
  let
    numPeersToShareWith = sqrt(ctx.peerPool.len.float32).int
    peers = ctx.getPeers(peer)

  debug "num peers to share with",
    number=numPeersToShareWith,
    numPeers=peers.len

  if peers.len > 0 and numPeersToShareWith > 0:
    asyncSpawn ctx.broadcastBlock(blk, peers[0..<numPeersToShareWith])

  var parentHash: Hash256
  if not ctx.chain.db.getBlockHash(ctx.finalizedBlock, parentHash):
    error "failed to get parent hash",
      number=ctx.finalizedBlock
    return

  if parentHash == blk.header.parentHash:
    # If new block is child of current chain tip, insert new block into chain
    let body = BlockBody(
      transactions: blk.txs,
      uncles: blk.uncles
    )
    let res = ctx.chain.persistBlocks([blk.header], [body])

    # Check if new sync target height can be set
    if res == ValidationResult.OK:
      ctx.endBlockNumber = blk.header.blockNumber
      ctx.finalizedBlock = blk.header.blockNumber

  else:
    # Call handleNewBlockHashes to retrieve all blocks between chain tip and new block
    let newSyncHeight = NewBlockHashesAnnounce(
      number: blk.header.blockNumber,
      hash: blk.header.blockHash
    )
    ctx.handleNewBlockHashes(peer, [newSyncHeight])

  if peers.len > 0 and numPeersToShareWith > 0:
    # Send `NEW_BLOCK_HASHES` message for received block to all other peers
    asyncSpawn ctx.broadcastBlockHash(blk, peers[numPeersToShareWith..^1])

proc newBlockHashesHandler*(arg: pointer,
                            peer: Peer,
                            hashes: openArray[NewBlockHashesAnnounce]) =
  let ctx = cast[LegacySyncRef](arg)
  ctx.handleNewBlockHashes(peer, hashes)

proc newBlockHandler*(arg: pointer,
                      peer: Peer,
                      blk: EthBlock,
                      totalDifficulty: DifficultyInt) {.
                        gcsafe, raises: [CatchableError].} =

  let ctx = cast[LegacySyncRef](arg)
  ctx.handleNewBlock(peer, blk, totalDifficulty)

# End

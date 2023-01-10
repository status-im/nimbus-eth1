import
  std/[tables, times, hashes, sets],
  chronicles, chronos,
  eth/p2p,
  eth/p2p/peer_pool,
  "."/[types, protocol],
  ./protocol/eth/eth_types,
  ./protocol/trace_config, # gossip noise control
  ../core/chain,
  ../core/tx_pool,
  ../core/tx_pool/tx_item

type
  HashToTime = TableRef[Hash256, Time]

  NewBlockHandler* = proc(
    arg: pointer,
    peer: Peer,
    blk: EthBlock,
    totalDifficulty: DifficultyInt) {.
      gcsafe, raises: [Defect, CatchableError].}

  NewBlockHashesHandler* = proc(
    arg: pointer,
    peer: Peer,
    hashes: openArray[NewBlockHashesAnnounce]) {.
      gcsafe, raises: [Defect, CatchableError].}

  NewBlockHandlerPair = object
    arg: pointer
    handler: NewBlockHandler

  NewBlockHashesHandlerPair = object
    arg: pointer
    handler: NewBlockHashesHandler

  EthWireRef* = ref object of EthWireBase
    db: ChainDBRef
    chain: ChainRef
    txPool: TxPoolRef
    peerPool: PeerPool
    disableTxPool: bool
    knownByPeer: Table[Peer, HashToTime]
    pending: HashSet[Hash256]
    lastCleanup: Time
    newBlockHandler: NewBlockHandlerPair
    newBlockHashesHandler: NewBlockHashesHandlerPair

  ReconnectRef = ref object
    pool: PeerPool
    node: Node

const
  NUM_PEERS_REBROADCAST_QUOTIENT = 4
  POOLED_STORAGE_TIME_LIMIT = initDuration(minutes = 20)
  PEER_LONG_BANTIME = chronos.minutes(150)

# ------------------------------------------------------------------------------
# Private functions: helper functions
# ------------------------------------------------------------------------------

proc notEnabled(name: string) =
  debug "Wire handler method is disabled", meth = name

proc notImplemented(name: string) =
  debug "Wire handler method not implemented", meth = name

proc inPool(ctx: EthWireRef, txHash: Hash256): bool =
  let res = ctx.txPool.getItem(txHash)
  res.isOk

proc inPoolAndOk(ctx: EthWireRef, txHash: Hash256): bool =
  let res = ctx.txPool.getItem(txHash)
  if res.isErr: return false
  res.get().reject == txInfoOk

proc successorHeader(db: ChainDBRef,
                     h: BlockHeader,
                     output: var BlockHeader,
                     skip = 0'u): bool {.gcsafe, raises: [Defect,RlpError].} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber <= (not 0.toBlockNumber) - offset:
    result = db.getBlockHeader(h.blockNumber + offset, output)

proc ancestorHeader(db: ChainDBRef,
                     h: BlockHeader,
                     output: var BlockHeader,
                     skip = 0'u): bool {.gcsafe, raises: [Defect,RlpError].} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber >= offset:
    result = db.getBlockHeader(h.blockNumber - offset, output)

proc blockHeader(db: ChainDBRef,
                 b: HashOrNum,
                 output: var BlockHeader): bool
                 {.gcsafe, raises: [Defect,RlpError].} =
  if b.isHash:
    db.getBlockHeader(b.hash, output)
  else:
    db.getBlockHeader(b.number, output)

# ------------------------------------------------------------------------------
# Private functions: peers related functions
# ------------------------------------------------------------------------------

proc hash(peer: Peer): hashes.Hash =
  hash(peer.remote)

proc getPeers(ctx: EthWireRef, thisPeer: Peer): seq[Peer] =
  # do not send back tx or txhash to thisPeer
  for peer in peers(ctx.peerPool):
    if peer != thisPeer:
      result.add peer

proc banExpiredReconnect(arg: pointer) {.gcsafe, raises: [Defect].} =
  # Reconnect to peer after ban period if pool is empty
  try:

    let reconnect = cast[ReconnectRef](arg)
    if reconnect.pool.len > 0:
      return

    asyncSpawn reconnect.pool.connectToNode(reconnect.node)

  except TransportError:
    debug "Transport got closed during banExpiredReconnect"
  except CatchableError as e:
    debug "Exception in banExpiredReconnect", exc = e.name, err = e.msg

proc banPeer(pool: PeerPool, peer: Peer, banTime: chronos.Duration) {.async.} =
  try:

    await peer.disconnect(SubprotocolReason)

    let expired = Moment.fromNow(banTime)
    let reconnect = ReconnectRef(
      pool: pool,
      node: peer.remote
    )

    discard setTimer(
      expired,
      banExpiredReconnect,
      cast[pointer](reconnect)
    )

  except TransportError:
    debug "Transport got closed during banPeer"
  except CatchableError as e:
    debug "Exception in banPeer", exc = e.name, err = e.msg

proc cleanupKnownByPeer(ctx: EthWireRef) =
  let now = getTime()
  var tmp = initHashSet[Hash256]()
  for _, map in ctx.knownByPeer:
    for hash, time in map:
      if time - now >= POOLED_STORAGE_TIME_LIMIT:
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

proc addToKnownByPeer(ctx: EthWireRef, txHashes: openArray[Hash256], peer: Peer) =
  var map: HashToTime
  ctx.knownByPeer.withValue(peer, val) do:
    map = val[]
  do:
    map = newTable[Hash256, Time]()
    ctx.knownByPeer[peer] = map

  for txHash in txHashes:
    if txHash notin map:
      map[txHash] = getTime()

proc addToKnownByPeer(ctx: EthWireRef,
                      txHashes: openArray[Hash256],
                      peer: Peer,
                      newHashes: var seq[Hash256]) =
  var map: HashToTime
  ctx.knownByPeer.withValue(peer, val) do:
    map = val[]
  do:
    map = newTable[Hash256, Time]()
    ctx.knownByPeer[peer] = map

  newHashes = newSeqOfCap[Hash256](txHashes.len)
  for txHash in txHashes:
    if txHash notin map:
      map[txHash] = getTime()
      newHashes.add txHash

# ------------------------------------------------------------------------------
# Private functions: async workers
# ------------------------------------------------------------------------------

proc sendNewTxHashes(ctx: EthWireRef,
                     txHashes: seq[Hash256],
                     peers: seq[Peer]): Future[void] {.async.} =
  try:

    for peer in peers:
      # Add to known tx hashes and get hashes still to send to peer
      var hashesToSend: seq[Hash256]
      ctx.addToKnownByPeer(txHashes, peer, hashesToSend)

      # Broadcast to peer if at least 1 new tx hash to announce
      if hashesToSend.len > 0:
        await peer.newPooledTransactionHashes(hashesToSend)

  except TransportError:
    debug "Transport got closed during sendNewTxHashes"
  except CatchableError as e:
    debug "Exception in sendNewTxHashes", exc = e.name, err = e.msg

proc sendTransactions(ctx: EthWireRef,
                      txHashes: seq[Hash256],
                      txs: seq[Transaction],
                      peers: seq[Peer]): Future[void] {.async.} =
  try:

    for peer in peers:
      # This is used to avoid re-sending along pooledTxHashes
      # announcements/re-broadcasts
      ctx.addToKnownByPeer(txHashes, peer)
      await peer.transactions(txs)

  except TransportError:
    debug "Transport got closed during sendTransactions"
  except CatchableError as e:
    debug "Exception in sendTransactions", exc = e.name, err = e.msg

proc fetchTransactions(ctx: EthWireRef, reqHashes: seq[Hash256], peer: Peer): Future[void] {.async.} =
  debug "fetchTx: requesting txs",
    number = reqHashes.len

  try:

    let res = await peer.getPooledTransactions(reqHashes)
    if res.isNone:
      error "not able to get pooled transactions"
      return

    let txs = res.unsafeGet.transactions

    # Remove from pending list regardless if tx is in result
    var poolTxs: seq[Transaction]
    for w in txs:
      if w.isSome:
        let tx = w.unsafeGet
        ctx.pending.excl rlpHash(tx)
        poolTxs.add tx

    debug "fetchTx: received requested txs", slots=txs.len, usable=poolTxs.len
    ctx.txPool.add(poolTxs)

  except TransportError:
    debug "Transport got closed during fetchTransactions"
    return
  except CatchableError as e:
    debug "Exception in fetchTransactions", exc = e.name, err = e.msg
    return

  var newTxHashes = newSeqOfCap[Hash256](reqHashes.len)
  for txHash in reqHashes:
    if ctx.inPoolAndOk(txHash):
      newTxHashes.add txHash

  let peers = ctx.getPeers(peer)
  if peers.len == 0 or newTxHashes.len == 0:
    return

  await ctx.sendNewTxHashes(newTxHashes, peers)

# ------------------------------------------------------------------------------
# Private functions: peer observer
# ------------------------------------------------------------------------------

proc onPeerConnected(ctx: EthWireRef, peer: Peer) =
  if ctx.disableTxPool:
    return

  var txHashes = newSeqOfCap[Hash256](ctx.txPool.numTxs)
  for txHash, item in okPairs(ctx.txPool):
    txHashes.add txHash

  if txHashes.len == 0:
    return

  debug "announce tx hashes to newly connected peer",
    number = txHashes.len

  asyncSpawn ctx.sendNewTxHashes(txHashes, @[peer])

proc onPeerDisconnected(ctx: EthWireRef, peer: Peer) =
  debug "ethwire: remove peer from knownByPeer",
    peer

  ctx.knownByPeer.del(peer)

proc setupPeerObserver(ctx: EthWireRef) =
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
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(_: type EthWireRef,
          chain: ChainRef,
          txPool: TxPoolRef,
          peerPool: PeerPool): EthWireRef =
  let ctx = EthWireRef(
    db: chain.db,
    chain: chain,
    txPool: txPool,
    peerPool: peerPool,
    lastCleanup: getTime(),
  )

  ctx.setupPeerObserver()
  ctx

# ------------------------------------------------------------------------------
# Public functions: callbacks setters
# ------------------------------------------------------------------------------

proc setNewBlockHandler*(ctx: EthWireRef, handler: NewBlockHandler, arg: pointer) =
  ctx.newBlockHandler = NewBlockHandlerPair(
    arg: arg,
    handler: handler
  )

proc setNewBlockHashesHandler*(ctx: EthWireRef, handler: NewBlockHashesHandler, arg: pointer) =
  ctx.newBlockHashesHandler = NewBlockHashesHandlerPair(
    arg: arg,
    handler: handler
  )

# ------------------------------------------------------------------------------
# Public functions: eth wire protocol handlers
# ------------------------------------------------------------------------------

proc txPoolEnabled*(ctx: EthWireRef; ena: bool) =
  ctx.disableTxPool = not ena

method getStatus*(ctx: EthWireRef): EthState {.gcsafe.} =
  let
    db = ctx.db
    com = ctx.chain.com
    bestBlock = db.getCanonicalHead()
    forkId = com.forkId(bestBlock.blockNumber)

  EthState(
    totalDifficulty: db.headTotalDifficulty,
    genesisHash: com.genesisHash,
    bestBlockHash: bestBlock.blockHash,
    forkId: ChainForkId(
      forkHash: forkId.crc.toBytesBE,
      forkNext: forkId.nextFork.toBlockNumber
    )
  )

method getReceipts*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[seq[Receipt]] {.gcsafe.} =
  let db = ctx.db
  var header: BlockHeader
  for blockHash in hashes:
    if db.getBlockHeader(blockHash, header):
      result.add db.getReceipts(header.receiptRoot)
    else:
      result.add @[]
      trace "handlers.getReceipts: blockHeader not found", blockHash

method getPooledTxs*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[PooledTx] {.gcsafe.} =
  let txPool = ctx.txPool
  var someActive = false
  for txHash in hashes:
    let res = txPool.getItem(txHash)
    if res.isOk:
      someActive = true
      result.add some(res.value.tx)
    else:
      result.add none(Transaction)
      trace "handlers.getPooledTxs: tx not found", txHash
  # github.com/ethereum/devp2p/blob/master/caps/eth.md#pooledtransactions-0x0a:
  #   A peer may respond with an empty list iff none of the hashes match
  #   transactions in its pool.
  if someActive:
    return @[]

method getBlockBodies*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[BlockBody] {.gcsafe.} =
  let db = ctx.db
  var body: BlockBody
  for blockHash in hashes:
    if db.getBlockBody(blockHash, body):
      result.add body
    else:
      result.add BlockBody()
      trace "handlers.getBlockBodies: blockBody not found", blockHash

method getBlockHeaders*(ctx: EthWireRef, req: BlocksRequest): seq[BlockHeader] {.gcsafe.} =
  let db = ctx.db
  var foundBlock: BlockHeader
  result = newSeqOfCap[BlockHeader](req.maxResults)

  if db.blockHeader(req.startBlock, foundBlock):
    result.add foundBlock

    while uint64(result.len) < req.maxResults:
      if not req.reverse:
        if not db.successorHeader(foundBlock, foundBlock, req.skip):
          break
      else:
        if not db.ancestorHeader(foundBlock, foundBlock, req.skip):
          break
      result.add foundBlock

method handleAnnouncedTxs*(ctx: EthWireRef, peer: Peer, txs: openArray[Transaction]) {.gcsafe.} =
  if ctx.disableTxPool:
    when trMissingOrDisabledGossipOk:
      notEnabled("handleAnnouncedTxs")
    return

  if txs.len == 0:
    return

  debug "received new transactions",
    number = txs.len

  if ctx.lastCleanup - getTime() > POOLED_STORAGE_TIME_LIMIT:
    ctx.cleanupKnownByPeer()

  var txHashes = newSeqOfCap[Hash256](txs.len)
  for tx in txs:
    txHashes.add rlpHash(tx)

  ctx.addToKnownByPeer(txHashes, peer)
  ctx.txPool.add(txs)

  var newTxHashes = newSeqOfCap[Hash256](txHashes.len)
  var validTxs = newSeqOfCap[Transaction](txHashes.len)
  for i, txHash in txHashes:
    if ctx.inPoolAndOk(txHash):
      newTxHashes.add txHash
      validTxs.add txs[i]

  let
    peers = ctx.getPeers(peer)
    numPeers = peers.len
    sendFull = max(1, numPeers div NUM_PEERS_REBROADCAST_QUOTIENT)

  if numPeers == 0 or validTxs.len == 0:
    return

  asyncSpawn ctx.sendTransactions(txHashes, validTxs, peers[0..<sendFull])

  asyncSpawn ctx.sendNewTxHashes(newTxHashes, peers[sendFull..^1])

method handleAnnouncedTxsHashes*(ctx: EthWireRef, peer: Peer, txHashes: openArray[Hash256]) {.gcsafe.} =
  if ctx.disableTxPool:
    when trMissingOrDisabledGossipOk:
      notEnabled("handleAnnouncedTxsHashes")
    return

  if txHashes.len == 0:
    return

  if ctx.lastCleanup - getTime() > POOLED_STORAGE_TIME_LIMIT:
    ctx.cleanupKnownByPeer()

  ctx.addToKnownByPeer(txHashes, peer)
  var reqHashes = newSeqOfCap[Hash256](txHashes.len)
  for txHash in txHashes:
    if txHash in ctx.pending or ctx.inPool(txHash):
      continue
    reqHashes.add txHash

  if reqHashes.len == 0:
    return

  debug "handleAnnouncedTxsHashes: received new tx hashes",
    number = reqHashes.len

  for txHash in reqHashes:
    ctx.pending.incl txHash

  asyncSpawn ctx.fetchTransactions(reqHashes, peer)

method handleNewBlock*(ctx: EthWireRef, peer: Peer, blk: EthBlock, totalDifficulty: DifficultyInt) {.gcsafe.} =
  if ctx.chain.com.forkGTE(MergeFork):
    debug "Dropping peer for sending NewBlock after merge (EIP-3675)",
      peer, blockNumber=blk.header.blockNumber,
      blockHash=blk.header.blockHash, totalDifficulty
    asyncSpawn banPeer(ctx.peerPool, peer, PEER_LONG_BANTIME)
    return

  if not ctx.newBlockHandler.handler.isNil:
    ctx.newBlockHandler.handler(
      ctx.newBlockHandler.arg,
      peer, blk, totalDifficulty
    )

method handleNewBlockHashes*(ctx: EthWireRef, peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) {.gcsafe.} =
  if ctx.chain.com.forkGTE(MergeFork):
    debug "Dropping peer for sending NewBlockHashes after merge (EIP-3675)",
      peer, numHashes=hashes.len
    asyncSpawn banPeer(ctx.peerPool, peer, PEER_LONG_BANTIME)
    return

  if not ctx.newBlockHashesHandler.handler.isNil:
    ctx.newBlockHashesHandler.handler(
      ctx.newBlockHashesHandler.arg,
      peer,
      hashes
    )

when defined(legacy_eth66_enabled):
  method getStorageNodes*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[Blob] {.gcsafe.} =
    let db = ctx.db.db
    for hash in hashes:
      result.add db.get(hash.data)

  method handleNodeData*(ctx: EthWireRef, peer: Peer, data: openArray[Blob]) {.gcsafe.} =
    notImplemented("handleNodeData")

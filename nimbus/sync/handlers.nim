import
  std/[tables, times, hashes, sets],
  chronicles, chronos,
  eth/[common, p2p, trie/db],
  eth/p2p/peer_pool,
  "."/[types, protocol],
  ./protocol/eth/eth_types,
  ./protocol/trace_config, # gossip noise control
  ../db/db_chain,
  ../p2p/chain,
  ../utils/tx_pool,
  ../utils/tx_pool/tx_item,
  ../merge/merger

type
  HashToTime = TableRef[Hash256, Time]

  EthWireRef* = ref object of EthWireBase
    db: BaseChainDB
    chain: Chain
    txPool: TxPoolRef
    peerPool: PeerPool
    disableTxPool: bool
    knownByPeer: Table[Peer, HashToTime]
    pending: HashSet[Hash256]
    lastCleanup: Time
    merger: MergerRef

  ReconnectRef = ref object
    pool: PeerPool
    node: Node

const
  NUM_PEERS_REBROADCAST_QUOTIENT = 4
  POOLED_STORAGE_TIME_LIMIT = initDuration(minutes = 20)
  PEER_LONG_BANTIME = chronos.minutes(150)

proc hash(peer: Peer): hashes.Hash =
  hash(peer.remote)

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

  ctx.lastCleanup = now

proc addToKnownByPeer(ctx: EthWireRef, txHashes: openArray[Hash256], peer: Peer) =
  var map: HashToTime
  if not ctx.knownByPeer.take(peer, map):
    map = newTable[Hash256, Time]()

  for txHash in txHashes:
    if txHash notin map:
      map[txHash] = getTime()

proc addToKnownByPeer(ctx: EthWireRef, txHashes: openArray[Hash256], peer: Peer, newHashes: var seq[Hash256]) =
  var map: HashToTime
  if not ctx.knownByPeer.take(peer, map):
    map = newTable[Hash256, Time]()

  newHashes = newSeqOfCap[Hash256](txHashes.len)
  for txHash in txHashes:
    if txHash notin map:
      map[txHash] = getTime()
      newHashes.add txHash

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

proc inPool(ctx: EthWireRef, txHash: Hash256): bool =
  let res = ctx.txPool.getItem(txHash)
  res.isOk

proc inPoolAndOk(ctx: EthWireRef, txHash: Hash256): bool =
  let res = ctx.txPool.getItem(txHash)
  if res.isErr: return false
  res.get().reject == txInfoOk

proc getPeers(ctx: EthWireRef, thisPeer: Peer): seq[Peer] =
  # do not send back tx or txhash to thisPeer
  for peer in peers(ctx.peerPool):
    if peer != thisPeer:
      result.add peer

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

proc new*(_: type EthWireRef,
          chain: Chain,
          txPool: TxPoolRef,
          peerPool: PeerPool,
          merger: MergerRef): EthWireRef =
  let ctx = EthWireRef(
    db: chain.db,
    chain: chain,
    txPool: txPool,
    peerPool: peerPool,
    merger: merger,
    lastCleanup: getTime(),
  )

  ctx.setupPeerObserver()
  ctx

proc notEnabled(name: string) =
  debug "Wire handler method is disabled", meth = name

proc notImplemented(name: string) =
  debug "Wire handler method not implemented", meth = name

proc txPoolEnabled*(ctx: EthWireRef; ena: bool) =
  ctx.disableTxPool = not ena

method getStatus*(ctx: EthWireRef): EthState {.gcsafe.} =
  let
    db = ctx.db
    chain = ctx.chain
    bestBlock = db.getCanonicalHead()
    forkId = chain.getForkId(bestBlock.blockNumber)

  EthState(
    totalDifficulty: db.headTotalDifficulty,
    genesisHash: chain.genesisHash,
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

method getPooledTxs*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[Transaction] {.gcsafe.} =
  let txPool = ctx.txPool
  for txHash in hashes:
    let res = txPool.getItem(txHash)
    if res.isOk:
      result.add res.value.tx
    else:
      result.add Transaction()
      trace "handlers.getPooledTxs: tx not found", txHash

method getBlockBodies*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[BlockBody] {.gcsafe.} =
  let db = ctx.db
  var body: BlockBody
  for blockHash in hashes:
    if db.getBlockBody(blockHash, body):
      result.add body
    else:
      result.add BlockBody()
      trace "handlers.getBlockBodies: blockBody not found", blockHash

proc successorHeader(db: BaseChainDB,
                     h: BlockHeader,
                     output: var BlockHeader,
                     skip = 0'u): bool {.gcsafe, raises: [Defect,RlpError].} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber <= (not 0.toBlockNumber) - offset:
    result = db.getBlockHeader(h.blockNumber + offset, output)

proc ancestorHeader*(db: BaseChainDB,
                     h: BlockHeader,
                     output: var BlockHeader,
                     skip = 0'u): bool {.gcsafe, raises: [Defect,RlpError].} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber >= offset:
    result = db.getBlockHeader(h.blockNumber - offset, output)

proc blockHeader(db: BaseChainDB,
                 b: HashOrNum,
                 output: var BlockHeader): bool
                 {.gcsafe, raises: [Defect,RlpError].} =
  if b.isHash:
    db.getBlockHeader(b.hash, output)
  else:
    db.getBlockHeader(b.number, output)

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
  ctx.txPool.jobAddTxs(txs)

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

proc fetchTransactions(ctx: EthWireRef, reqHashes: seq[Hash256], peer: Peer): Future[void] {.async.} =
  debug "fetchTx: requesting txs",
    number = reqHashes.len

  try:

    let res = await peer.getPooledTransactions(reqHashes)
    if res.isNone:
      error "not able to get pooled transactions"
      return

    let txs = res.get()
    debug "fetchTx: received requested txs",
      number = txs.transactions.len

    # Remove from pending list regardless if tx is in result
    for tx in txs.transactions:
      let txHash = rlpHash(tx)
      ctx.pending.excl txHash

    ctx.txPool.jobAddTxs(txs.transactions)

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
  if ctx.merger.posFinalized:
    debug "Dropping peer for sending NewBlock after merge (EIP-3675)",
      peer, blockNumber=blk.header.blockNumber,
      blockHash=blk.header.blockHash, totalDifficulty
    asyncSpawn banPeer(ctx.peerPool, peer, PEER_LONG_BANTIME)
    return

method handleNewBlockHashes*(ctx: EthWireRef, peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) {.gcsafe.} =
  if ctx.merger.posFinalized:
    debug "Dropping peer for sending NewBlockHashes after merge (EIP-3675)",
      peer, numHashes=hashes.len
    asyncSpawn banPeer(ctx.peerPool, peer, PEER_LONG_BANTIME)
    return

when defined(legacy_eth66_enabled):
  method getStorageNodes*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[Blob] {.gcsafe.} =
    let db = ctx.db.db
    for hash in hashes:
      result.add db.get(hash.data)

  method handleNodeData*(ctx: EthWireRef, peer: Peer, data: openArray[Blob]) {.gcsafe.} =
    notImplemented("handleNodeData")

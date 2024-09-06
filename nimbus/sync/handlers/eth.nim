# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[tables, times, hashes, sets],
  chronicles, chronos,
  stew/endians2,
  eth/p2p,
  eth/p2p/peer_pool,
  ".."/[types, protocol],
  ../protocol/eth/eth_types,
  ../../core/[chain, tx_pool]

logScope:
  topics = "eth-wire"

type
  HashToTime = TableRef[Hash256, Time]

  EthWireRef* = ref object of EthWireBase
    db: CoreDbRef
    chain: ForkedChainRef
    txPool: TxPoolRef
    peerPool: PeerPool
    knownByPeer: Table[Peer, HashToTime]
    pending: HashSet[Hash256]
    lastCleanup: Time

const
  extraTraceMessages = false
    ## Enabled additional logging noise

  txpool_enabled = defined(enable_txpool_in_synchronizer)

when txpool_enabled:
  const
    NUM_PEERS_REBROADCAST_QUOTIENT = 4
    POOLED_STORAGE_TIME_LIMIT = initDuration(minutes = 20)

# ------------------------------------------------------------------------------
# Private functions: helper functions
# ------------------------------------------------------------------------------

proc notEnabled(name: string) {.used.} =
  debug "Wire handler method is disabled", meth = name

proc notImplemented(name: string) {.used.} =
  debug "Wire handler method not implemented", meth = name

proc successorHeader(db: CoreDbRef,
                     h: BlockHeader,
                     output: var BlockHeader,
                     skip = 0'u): bool =
  let offset = 1 + skip.BlockNumber
  if h.number <= (not 0.BlockNumber) - offset:
    result = db.getBlockHeader(h.number + offset, output)

proc ancestorHeader(db: CoreDbRef,
                     h: BlockHeader,
                     output: var BlockHeader,
                     skip = 0'u): bool =
  let offset = 1 + skip.BlockNumber
  if h.number >= offset:
    result = db.getBlockHeader(h.number - offset, output)

proc blockHeader(db: CoreDbRef,
                 b: HashOrNum,
                 output: var BlockHeader): bool =
  if b.isHash:
    db.getBlockHeader(b.hash, output)
  else:
    db.getBlockHeader(b.number, output)

# ------------------------------------------------------------------------------
# Private functions: peers related functions
# ------------------------------------------------------------------------------

proc hash(peer: Peer): hashes.Hash {.used.} =
  hash(peer.remote)

when txpool_enabled:
  proc getPeers(ctx: EthWireRef, thisPeer: Peer): seq[Peer] =
    # do not send back tx or txhash to thisPeer
    for peer in peers(ctx.peerPool):
      if peer != thisPeer:
        result.add peer

  proc cleanupKnownByPeer(ctx: EthWireRef) =
    let now = getTime()
    var tmp = HashSet[Hash256]()
    for _, map in ctx.knownByPeer:
      for hash, time in map:
        if time - now >= POOLED_STORAGE_TIME_LIMIT:
          tmp.incl hash
      for hash in tmp:
        map.del(hash)
      tmp.clear()

    var tmpPeer = HashSet[Peer]()
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

when txpool_enabled:
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
          # Currently only one protocol version is available as compiled
          when ethVersion == 68:
            await newPooledTransactionHashes(
              peer,
              1u8.repeat hashesToSend.len, # type
              0.repeat hashesToSend.len,   # sizes
              hashesToSend)
          else:
            await newPooledTransactionHashes(peer, hashesToSend)

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

      let txs = res.get()
      debug "fetchTx: received requested txs",
        number = txs.transactions.len

      # Remove from pending list regardless if tx is in result
      for tx in txs.transactions:
        let txHash = rlpHash(tx)
        ctx.pending.excl txHash

      ctx.txPool.add(txs.transactions)

    except TransportError:
      debug "Transport got closed during fetchTransactions"
      return
    except CatchableError as e:
      debug "Exception in fetchTransactions", exc = e.name, err = e.msg
      return

    var newTxHashes = newSeqOfCap[Hash256](reqHashes.len)
    for txHash in reqHashes:
      if ctx.txPool.inPoolAndOk(txHash):
        newTxHashes.add txHash

    let peers = ctx.getPeers(peer)
    if peers.len == 0 or newTxHashes.len == 0:
      return

    await ctx.sendNewTxHashes(newTxHashes, peers)

# ------------------------------------------------------------------------------
# Private functions: peer observer
# ------------------------------------------------------------------------------

proc onPeerConnected(ctx: EthWireRef, peer: Peer) =
  when txpool_enabled:
    var txHashes = newSeqOfCap[Hash256](ctx.txPool.numTxs)
    for txHash, item in okPairs(ctx.txPool):
      txHashes.add txHash

    if txHashes.len == 0:
      return

    debug "announce tx hashes to newly connected peer",
      number = txHashes.len

    asyncSpawn ctx.sendNewTxHashes(txHashes, @[peer])
  else:
    discard

proc onPeerDisconnected(ctx: EthWireRef, peer: Peer) =
  debug "remove peer from knownByPeer",
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
  po.setProtocol protocol.eth
  ctx.peerPool.addObserver(ctx, po)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(_: type EthWireRef,
          chain: ForkedChainRef,
          txPool: TxPoolRef,
          peerPool: PeerPool): EthWireRef =
  let ctx = EthWireRef(
    db: chain.db,
    chain: chain,
    txPool: txPool,
    peerPool: peerPool,
    lastCleanup: getTime())

  ctx.setupPeerObserver()
  ctx

# ------------------------------------------------------------------------------
# Public functions: eth wire protocol handlers
# ------------------------------------------------------------------------------

method getStatus*(ctx: EthWireRef): Result[EthState, string]
    {.gcsafe.} =
  try:
    let
      db = ctx.db
      com = ctx.chain.com
      bestBlock = db.getCanonicalHead()
      forkId = com.forkId(bestBlock.number, bestBlock.timestamp)

    return ok(EthState(
      totalDifficulty: db.headTotalDifficulty,
      genesisHash: com.genesisHash,
      bestBlockHash: bestBlock.blockHash,
      forkId: ChainForkId(
        forkHash: forkId.crc.toBytesBE,
        forkNext: forkId.nextFork
      )
    ))
  except EVMError as exc:
    # TODO: Why an EVM Error in database?
    return err(exc.msg)
  except RlpError as exc:
    return err(exc.msg)

method getReceipts*(ctx: EthWireRef,
                    hashes: openArray[Hash256]):
                      Result[seq[seq[Receipt]], string]
    {.gcsafe.} =
  try:
    let db = ctx.db
    var header: BlockHeader
    var list: seq[seq[Receipt]]
    for blockHash in hashes:
      if db.getBlockHeader(blockHash, header):
        list.add db.getReceipts(header.receiptsRoot)
      else:
        list.add @[]
        trace "handlers.getReceipts: blockHeader not found", blockHash
    return ok(list)
  except RlpError as exc:
    return err(exc.msg)

method getPooledTxs*(ctx: EthWireRef,
                     hashes: openArray[Hash256]):
                       Result[seq[PooledTransaction], string]
    {.gcsafe.} =

  when txpool_enabled:
    let txPool = ctx.txPool
    var list: seq[PooledTransaction]
    for txHash in hashes:
      let res = txPool.getItem(txHash)
      if res.isOk:
        list.add res.value.pooledTx
      else:
        trace "handlers.getPooledTxs: tx not found", txHash
    ok(list)
  else:
    var list: seq[PooledTransaction]
    ok(list)

method getBlockBodies*(ctx: EthWireRef,
                       hashes: openArray[Hash256]):
                        Result[seq[BlockBody], string]
    {.gcsafe.} =
  let db = ctx.db
  var body: BlockBody
  var list: seq[BlockBody]
  for blockHash in hashes:
    if db.getBlockBody(blockHash, body):
      list.add body
    else:
      list.add BlockBody()
      trace "handlers.getBlockBodies: blockBody not found", blockHash
  return ok(list)

method getBlockHeaders*(ctx: EthWireRef,
                        req: BlocksRequest):
                          Result[seq[BlockHeader], string]
    {.gcsafe.} =
  try:
    let db = ctx.db
    var foundBlock: BlockHeader
    var list = newSeqOfCap[BlockHeader](req.maxResults)

    if db.blockHeader(req.startBlock, foundBlock):
      list.add foundBlock

      while uint64(list.len) < req.maxResults:
        if not req.reverse:
          if not db.successorHeader(foundBlock, foundBlock, req.skip):
            break
        else:
          if not db.ancestorHeader(foundBlock, foundBlock, req.skip):
            break
        list.add foundBlock
    return ok(list)
  except RlpError as exc:
    return err(exc.msg)

method handleAnnouncedTxs*(ctx: EthWireRef,
                           peer: Peer,
                           txs: openArray[Transaction]):
                             Result[void, string]
    {.gcsafe.} =

  when txpool_enabled:
    try:
      if txs.len == 0:
        return ok()

      debug "received new transactions",
        number = txs.len

      if ctx.lastCleanup - getTime() > POOLED_STORAGE_TIME_LIMIT:
        ctx.cleanupKnownByPeer()

      var txHashes = newSeqOfCap[Hash256](txs.len)
      for tx in txs:
        txHashes.add rlpHash(tx)

      ctx.addToKnownByPeer(txHashes, peer)
      for tx in txs:
        if tx.versionedHashes.len > 0:
          # EIP-4844 blobs are not persisted and cannot be broadcasted
          continue
        ctx.txPool.add PooledTransaction(tx: tx)

      var newTxHashes = newSeqOfCap[Hash256](txHashes.len)
      var validTxs = newSeqOfCap[Transaction](txHashes.len)
      for i, txHash in txHashes:
        # Nodes must not automatically broadcast blob transactions to
        # their peers. per EIP-4844 spec
        if ctx.txPool.inPoolAndOk(txHash) and txs[i].txType != TxEip4844:
          newTxHashes.add txHash
          validTxs.add txs[i]

      let
        peers = ctx.getPeers(peer)
        numPeers = peers.len
        sendFull = max(1, numPeers div NUM_PEERS_REBROADCAST_QUOTIENT)

      if numPeers == 0 or validTxs.len == 0:
        return ok()

      asyncSpawn ctx.sendTransactions(txHashes, validTxs, peers[0..<sendFull])

      asyncSpawn ctx.sendNewTxHashes(newTxHashes, peers[sendFull..^1])
      return ok()
    except CatchableError as exc:
      return err(exc.msg)
  else:
    ok()

method handleAnnouncedTxsHashes*(
      ctx: EthWireRef;
      peer: Peer;
      txTypes: Blob;
      txSizes: openArray[int];
      txHashes: openArray[Hash256];
        ): Result[void, string] =
  when extraTraceMessages:
    trace "Wire handler ignoring txs hashes", nHashes=txHashes.len
  ok()

method handleNewBlock*(ctx: EthWireRef,
                       peer: Peer,
                       blk: EthBlock,
                       totalDifficulty: DifficultyInt):
                         Result[void, string]
    {.gcsafe.} =
  # We dropped support for non-merge networks
  err("block broadcasts disallowed")

method handleNewBlockHashes*(ctx: EthWireRef,
                             peer: Peer,
                             hashes: openArray[NewBlockHashesAnnounce]):
                               Result[void, string]
    {.gcsafe.} =
  # We dropped support for non-merge networks
  err("block announcements disallowed")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

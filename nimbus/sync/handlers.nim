import
  chronicles,
  eth/[common, p2p, trie/db],
  ./types,
  ./protocol/eth/eth_types,
  ./protocol/trace_config, # gossip noise control
  ../db/db_chain,
  ../p2p/chain,
  ../utils/tx_pool

type
  EthWireRef* = ref object of EthWireBase
    db: BaseChainDB
    chain: Chain
    txPool: TxPoolRef
    disablePool: bool

proc new*(_: type EthWireRef, chain: Chain, txPool: TxPoolRef): EthWireRef =
  EthWireRef(
    db: chain.db,
    chain: chain,
    txPool: txPool
  )

proc notEnabled(name: string) =
  debug "Wire handler method is disabled", meth = name

proc notImplemented(name: string) =
  debug "Wire handler method not implemented", meth = name

method poolEnabled*(ctx: EthWireRef; ena: bool) =
  ctx.disablePool = not ena

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
  if ctx.disablePool:
    when trMissingOrDisabledGossipOk:
      notEnabled("handleAnnouncedTxs")
  else:
    ctx.txPool.jobAddTxs(txs)

method handleAnnouncedTxsHashes*(ctx: EthWireRef, peer: Peer, txHashes: openArray[Hash256]) {.gcsafe.} =
  when trMissingOrDisabledGossipOk:
    notImplemented("handleAnnouncedTxsHashes")

method handleNewBlock*(ctx: EthWireRef, peer: Peer, blk: EthBlock, totalDifficulty: DifficultyInt) {.gcsafe.} =
  notImplemented("handleNewBlock")

method handleNewBlockHashes*(ctx: EthWireRef, peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) {.gcsafe.} =
  notImplemented("handleNewBlockHashes")

when defined(legacy_eth66_enabled):
  method getStorageNodes*(ctx: EthWireRef, hashes: openArray[Hash256]): seq[Blob] {.gcsafe.} =
    let db = ctx.db.db
    for hash in hashes:
      result.add db.get(hash.data)

  method handleNodeData*(ctx: EthWireRef, peer: Peer, data: openArray[Blob]) {.gcsafe.} =
    notImplemented("handleNodeData")

# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  chronicles,
  chronos,
  stint,
  json_serialization,
  stew/byteutils,
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../../nimbus/common/chain_config,
  ../../common/common_utils,
  ../../rpc/rpc_calls/rpc_trace_calls,
  ../../rpc/portal_rpc_client,
  ../../network/state/[state_content, state_gossip],
  ./state_bridge/[database, state_diff, world_state_helper, offers_builder],
  ./[portal_bridge_conf, portal_bridge_common]

type BlockData = object
  blockNumber: uint64
  blockHash: KeccakHash
  miner: EthAddress
  uncles: seq[tuple[miner: EthAddress, blockNumber: uint64]]
  parentStateRoot: KeccakHash
  stateRoot: KeccakHash
  stateDiffs: seq[TransactionDiff]

type BlockOffersRef = ref object
  blockNumber: uint64
  accountTrieOffers: seq[AccountTrieOfferWithKey]
  contractTrieOffers: seq[ContractTrieOfferWithKey]
  contractCodeOffers: seq[ContractCodeOfferWithKey]

proc getBlockData(db: DatabaseRef, blockNumber: uint64): Opt[BlockData] =
  let blockDataBytes = db.get(rlp.encode(blockNumber))
  if blockDataBytes.len() == 0:
    return Opt.none(BlockData)

  try:
    Opt.some(rlp.decode(blockDataBytes, BlockData))
  except RlpError as e:
    raiseAssert(e.msg) # Should never happen

proc putBlockData(
    db: DatabaseRef, blockNumber: uint64, blockData: BlockData
) {.inline.} =
  db.put(rlp.encode(blockNumber), rlp.encode(blockData))

proc getLastPersistedBlockNumber(db: DatabaseRef): Opt[uint64] =
  let blockNumberBytes = db.get(rlp.encode("lastPersistedBlockNumber"))
  if blockNumberBytes.len() == 0:
    return Opt.none(uint64)

  try:
    Opt.some(rlp.decode(blockNumberBytes, uint64))
  except RlpError as e:
    raiseAssert(e.msg) # Should never happen

proc putLastPersistedBlockNumber(db: DatabaseRef, blockNumber: uint64) {.inline.} =
  # Only update the last persisted block number if it's greater than the current one
  if blockNumber > db.getLastPersistedBlockNumber().valueOr(0):
    db.put(rlp.encode("lastPersistedBlockNumber"), rlp.encode(blockNumber))

proc runBackfillCollectBlockDataLoop(
    db: DatabaseRef,
    blockDataQueue: AsyncQueue[BlockData],
    web3Client: RpcClient,
    startBlockNumber: uint64,
) {.async: (raises: [CancelledError]).} =
  info "Starting state backfill collect block data loop"

  let parentBlock = (
    await web3Client.getBlockByNumber(blockId(startBlockNumber - 1.uint64), false)
  ).valueOr:
    raiseAssert("Failed to get parent block")

  var
    parentStateRoot = parentBlock.stateRoot
    currentBlockNumber = startBlockNumber

  while true:
    if currentBlockNumber mod 10000 == 0:
      info "Collecting block data for block number: ", blockNumber = currentBlockNumber

    let blockData = db.getBlockData(currentBlockNumber).valueOr:
      # block data doesn't exist in db so we fetch it via RPC
      let
        blockId = blockId(currentBlockNumber)
        blockObject = (await web3Client.getBlockByNumber(blockId, false)).valueOr:
          error "Failed to get block", error
          await sleepAsync(1.seconds)
          continue
        stateDiffs = (await web3Client.getStateDiffsByBlockNumber(blockId)).valueOr:
          error "Failed to get state diffs", error
          await sleepAsync(1.seconds)
          continue

      var uncleBlocks: seq[BlockObject]
      for i in 0 .. blockObject.uncles.high:
        let uncleBlock = (
          await web3Client.getUncleByBlockNumberAndIndex(blockId, i.Quantity)
        ).valueOr:
          error "Failed to get uncle block", error
          await sleepAsync(1.seconds)
          continue
        uncleBlocks.add(uncleBlock)

      let blockData = BlockData(
        blockNumber: currentBlockNumber,
        blockHash: KeccakHash.fromBytes(blockObject.hash.bytes()),
        miner: blockObject.miner.EthAddress,
        uncles: uncleBlocks.mapIt((it.miner.EthAddress, it.number.uint64)),
        parentStateRoot: KeccakHash.fromBytes(parentStateRoot.bytes()),
        stateRoot: KeccakHash.fromBytes(blockObject.stateRoot.bytes()),
        stateDiffs: stateDiffs,
      )
      db.putBlockData(currentBlockNumber, blockData)

      parentStateRoot = blockObject.stateRoot
      blockData

    await blockDataQueue.addLast(blockData)
    inc currentBlockNumber

proc runBackfillBuildBlockOffersLoop(
    db: DatabaseRef,
    blockDataQueue: AsyncQueue[BlockData],
    blockOffersQueue: AsyncQueue[BlockOffersRef],
) {.async: (raises: [CancelledError]).} =
  info "Starting state backfill build block offers loop"

  # wait for the first block data to be put on the queue
  # so that we can access the first block once available
  while blockDataQueue.empty():
    await sleepAsync(100.milliseconds)
  # peek but don't remove it so that it can be processed later
  let firstBlock = blockDataQueue[0]

  # Only apply genesis accounts if starting from block 1
  if firstBlock.blockNumber == 1:
    info "Building state for genesis"

    db.withTransaction:
      # Requires an active transaction because it writes an emptyRlp node
      # to the accounts HexaryTrie on initialization
      let
        ws = WorldStateRef.init(db)
        genesisAccounts =
          try:
            genesisBlockForNetwork(MainNet).alloc
          except CatchableError as e:
            raiseAssert(e.msg) # Should never happen
      ws.applyGenesisAccounts(genesisAccounts)

      let genesisBlockHash = KeccakHash.fromHex(
        "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      )
      var builder = OffersBuilderRef.init(ws, genesisBlockHash)
      builder.buildBlockOffers()

      await blockOffersQueue.addLast(
        BlockOffersRef(
          blockNumber: 0.uint64,
          accountTrieOffers: builder.getAccountTrieOffers(),
          contractTrieOffers: builder.getContractTrieOffers(),
          contractCodeOffers: builder.getContractCodeOffers(),
        )
      )

  # Load the world state using the parent state root
  let worldState = WorldStateRef.init(db, firstBlock.parentStateRoot)

  while true:
    let blockData = await blockDataQueue.popFirst()

    if blockData.blockNumber mod 10000 == 0:
      info "Building state for block number: ", blockNumber = blockData.blockNumber

    # For now all WorldStateRef functions need to be inside a transaction
    # because the DatabaseRef backends currently only supports reading and
    # writing to/from a single active transaction.
    db.withTransaction:
      for stateDiff in blockData.stateDiffs:
        worldState.applyStateDiff(stateDiff)

      worldState.applyBlockRewards(
        (blockData.miner, blockData.blockNumber), blockData.uncles
      )

      if blockData.blockNumber == 1_920_000:
        info "Applying state updates for DAO hard fork"
        worldState.applyDAOHardFork()

      doAssert(
        worldState.stateRoot == blockData.stateRoot,
        "State root mismatch at block number: " & $blockData.blockNumber,
      )
      trace "State diffs successfully applied to block number:",
        blockNumber = blockData.blockNumber

      # TODO: make this configurable
      worldState.verifyProofs(blockData.parentStateRoot, blockData.stateRoot)

      var builder = OffersBuilderRef.init(worldState, blockData.blockHash)
      builder.buildBlockOffers()

      await blockOffersQueue.addLast(
        BlockOffersRef(
          blockNumber: blockData.blockNumber,
          accountTrieOffers: builder.getAccountTrieOffers(),
          contractTrieOffers: builder.getContractTrieOffers(),
          contractCodeOffers: builder.getContractCodeOffers(),
        )
      )

    # After commit of the above db transaction which stores the updated account state
    # then we store the last persisted block number in the database so that we can use it
    # to enable restarting from this block if needed
    db.putLastPersistedBlockNumber(blockData.blockNumber)

proc collectOffer(
    offersMap: TableRef[seq[byte], seq[byte]],
    offerWithKey:
      AccountTrieOfferWithKey | ContractTrieOfferWithKey | ContractCodeOfferWithKey,
) =
  let
    keyBytes = offerWithKey.key.toContentKey().encode().asSeq()
    offerBytes = offerWithKey.offer.encode()
  offersMap[keyBytes] = offerBytes

proc recursiveCollectOffer(
    offersMap: TableRef[seq[byte], seq[byte]],
    offerWithKey: AccountTrieOfferWithKey | ContractTrieOfferWithKey,
) =
  offersMap.collectOffer(offerWithKey)

  # root node, recursive collect is finished
  if offerWithKey.key.path.unpackNibbles().len() == 0:
    return

  # continue the recursive collect
  offersMap.recursiveCollectOffer(offerWithKey.getParent())

proc runBackfillGossipBlockOffersLoop(
    blockOffersQueue: AsyncQueue[BlockOffersRef], portalClient: RpcClient, workerId: int
) {.async: (raises: [CancelledError]).} =
  info "Starting state backfill gossip block offers loop"

  var blockOffers = await blockOffersQueue.popFirst()

  while true:
    # A table of offer key, value pairs is used to filter out duplicates so
    # that we don't gossip the same offer multiple times.
    let offersMap = newTable[seq[byte], seq[byte]]()

    for offerWithKey in blockOffers.accountTrieOffers:
      offersMap.recursiveCollectOffer(offerWithKey)
    for offerWithKey in blockOffers.contractTrieOffers:
      offersMap.recursiveCollectOffer(offerWithKey)
    for offerWithKey in blockOffers.contractCodeOffers:
      offersMap.collectOffer(offerWithKey)

    let gossipBatch = portalClient.prepareBatch()
    for k, v in offersMap:
      gossipBatch.portal_stateGossip(k.to0xHex(), v.to0xHex())
    let gossipResponses = (await gossipBatch.send()).valueOr:
      error "Failed to send portal_stateGossip batch", error
      await sleepAsync(1.seconds)
      continue

    var retryGossip = false
    for r in gossipResponses:
      if r.error.isSome:
        error "Failed to gossip offer to peers: ", error = r.error.get
        retryGossip = true
        break
      try:
        let numPeers = Json.decode(r.result.string, int)
        if numPeers == 0:
          warn "Offer gossipped to no peers: ", numPeers
          retryGossip = true
          break
      except SerializationError as e:
        raiseAssert(e.msg) # Should never happen

    if retryGossip:
      await sleepAsync(1.seconds)
      continue

    # TODO: make this configurable
    await sleepAsync(100.milliseconds) # wait for the peers to be updated
    let findBatch = portalClient.prepareBatch()
    for k, _ in offersMap:
      findBatch.portal_stateRecursiveFindContent(k.to0xHex())
    let findResponses = (await findBatch.send()).valueOr:
      error "Failed to send portal_stateRecursiveFindContent batch", error
      await sleepAsync(1.seconds)
      continue

    for r in findResponses:
      if r.error.isSome:
        warn "Failed to find contentValue, retrying gossip: ",
          workerId, error = r.error.get
        retryGossip = true
        break
      try:
        let contentInfo = Json.decode(r.result.string, ContentInfo)
        if contentInfo.content.len() == 0:
          error "Found empty contentValue: ", contentValue = contentInfo.content
          retryGossip = true
          break
      except SerializationError as e:
        raiseAssert(e.msg) # Should never happen

    if retryGossip:
      await sleepAsync(1.seconds)
      continue

    if blockOffers.blockNumber mod 1000 == 0:
      info "Finished gossiping offers for block number: ",
        workerId, blockNumber = blockOffers.blockNumber, offerCount = offersMap.len()

    blockOffers = await blockOffersQueue.popFirst()

proc runBackfillMetricsLoop(
    blockDataQueue: AsyncQueue[BlockData], blockOffersQueue: AsyncQueue[BlockOffersRef]
) {.async: (raises: [CancelledError]).} =
  info "Starting state backfill metrics loop"

  while true:
    await sleepAsync(10.seconds)
    info "Block data queue length: ", blockDataQueueLen = blockDataQueue.len()
    info "Block offers queue length: ", blockOffersQueueLen = blockOffersQueue.len()

proc runState*(config: PortalBridgeConf) =
  let
    portalClient = newRpcClientConnect(config.portalRpcUrl)
    web3Client = newRpcClientConnect(config.web3UrlState)
    db = DatabaseRef.init(config.stateDir.string).get()
  defer:
    db.close()

  if web3Client of RpcHttpClient:
    warn "Using a WebSocket connection to the JSON-RPC API is recommended to improve performance"

  # TODO:
  # Here we'd want to implement initially a loop that backfills the state
  # content. Secondly, a loop that follows the head and injects the latest
  # state changes too.
  #
  # The first step would probably be the easier one to start with, as one
  # can start from genesis state.
  # It could be implemented by using the `exp_getProofsByBlockNumber` JSON-RPC
  # method from nimbus-eth1.
  # It could also be implemented by having the whole state execution happening
  # inside the bridge, and getting the blocks from era1 files.

  if config.backfillState:
    let maybeLastPersistedBlock = db.getLastPersistedBlockNumber()
    if maybeLastPersistedBlock.isSome():
      info "Last persisted block found in the database: ",
        lastPersistedBlock = maybeLastPersistedBlock.get()
      if config.startBlockNumber < 1 or
          config.startBlockNumber > maybeLastPersistedBlock.get():
        warn "Start block must be set to a value between 1 and the last persisted block"
        quit QuitFailure
    else:
      info "No last persisted block found in the database"
      if config.startBlockNumber != 1:
        warn "Start block must be set to 1"
        quit QuitFailure

    info "Starting state backfill from block number: ",
      startBlockNumber = config.startBlockNumber

    const
      gossipOffersWorkerCount = 5 # TODO: make this configurable
      bufferSize = 1000 # TODO: make this configurable
    let
      blockDataQueue = newAsyncQueue[BlockData](bufferSize)
      blockOffersQueue = newAsyncQueue[BlockOffersRef](bufferSize)

    asyncSpawn runBackfillCollectBlockDataLoop(
      db, blockDataQueue, web3Client, config.startBlockNumber
    )
    asyncSpawn runBackfillBuildBlockOffersLoop(db, blockDataQueue, blockOffersQueue)

    for workerId in 1 .. gossipOffersWorkerCount:
      asyncSpawn runBackfillGossipBlockOffersLoop(
        blockOffersQueue, portalClient, workerId
      )

    asyncSpawn runBackfillMetricsLoop(blockDataQueue, blockOffersQueue)

  while true:
    poll()

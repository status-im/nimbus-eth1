# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, algorithm],
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
    verifyStateProofs: bool,
    gossipGenesis: bool,
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

      if gossipGenesis:
        let genesisBlockHash = KeccakHash.fromHex(
          "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
        )
        var builder = OffersBuilder.init(ws, genesisBlockHash)
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

      if verifyStateProofs:
        worldState.verifyProofs(blockData.parentStateRoot, blockData.stateRoot)

      var builder = OffersBuilder.init(worldState, blockData.blockHash)
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
    offersMap: OrderedTableRef[seq[byte], seq[byte]],
    offerWithKey:
      AccountTrieOfferWithKey | ContractTrieOfferWithKey | ContractCodeOfferWithKey,
) {.inline.} =
  let keyBytes = offerWithKey.key.toContentKey().encode().asSeq()
  offersMap[keyBytes] = offerWithKey.offer.encode()

proc recursiveCollectOffer(
    offersMap: OrderedTableRef[seq[byte], seq[byte]],
    offerWithKey: AccountTrieOfferWithKey | ContractTrieOfferWithKey,
) =
  offersMap.collectOffer(offerWithKey)

  # root node, recursive collect is finished
  if offerWithKey.key.path.unpackNibbles().len() == 0:
    return

  # continue the recursive collect
  offersMap.recursiveCollectOffer(offerWithKey.getParent())

proc runBackfillGossipBlockOffersLoop(
    blockOffersQueue: AsyncQueue[BlockOffersRef],
    portalClient: RpcClient,
    portalNodeId: NodeId,
    verifyGossip: bool,
    workerId: int,
) {.async: (raises: [CancelledError]).} =
  info "Starting state backfill gossip block offers loop", workerId

  var blockOffers = await blockOffersQueue.popFirst()

  while true:
    # A table of offer key, value pairs is used to filter out duplicates so
    # that we don't gossip the same offer multiple times.
    let offersMap = newOrderedTable[seq[byte], seq[byte]]()

    for offerWithKey in blockOffers.accountTrieOffers:
      offersMap.recursiveCollectOffer(offerWithKey)
    for offerWithKey in blockOffers.contractTrieOffers:
      offersMap.recursiveCollectOffer(offerWithKey)
    for offerWithKey in blockOffers.contractCodeOffers:
      offersMap.collectOffer(offerWithKey)

    # We need to use a closure here because nodeId is required to calculate the
    # distance of each content id from the node
    proc offersMapCmp(x, y: (seq[byte], seq[byte])): int =
      let
        xId = ContentKeyByteList.init(x[0]).toContentId()
        yId = ContentKeyByteList.init(y[0]).toContentId()
        xDistance = portalNodeId xor xId
        yDistance = portalNodeId xor yId

      if xDistance == yDistance:
        0
      elif xDistance > yDistance:
        1
      else:
        -1

    # Sort the offers based on the distance from the node so that we will gossip
    # content that is closest to the node first
    offersMap.sort(offersMapCmp)

    var retryGossip = false
    for k, v in offersMap:
      try:
        let numPeers = await portalClient.portal_stateGossip(k.to0xHex(), v.to0xHex())
        if numPeers > 0:
          debug "Offer successfully gossipped to peers: ", numPeers, workerId
        elif numPeers == 0:
          warn "Offer gossipped to no peers", workerId
          retryGossip = true
          break
      except CatchableError as e:
        error "Failed to gossip offer to peers", error = e.msg, workerId
        retryGossip = true
        break

    if retryGossip:
      await sleepAsync(3.seconds)
      warn "Retrying state gossip for block number: ",
        blockNumber = blockOffers.blockNumber, workerId
      continue

    if verifyGossip:
      await sleepAsync(100.milliseconds) # wait for the peers to be updated
      for k, _ in offersMap:
        try:
          let contentInfo =
            await portalClient.portal_stateRecursiveFindContent(k.to0xHex())
          if contentInfo.content.len() == 0:
            error "Found empty contentValue", workerId
            retryGossip = true
            break
        except CatchableError as e:
          warn "Failed to find content with key: ",
            contentKey = k, error = e.msg, workerId
          retryGossip = true
          break

      if retryGossip:
        await sleepAsync(3.seconds)
        warn "Retrying state gossip for block number: ",
          blockNumber = blockOffers.blockNumber
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
    await sleepAsync(30.seconds)
    info "Block data queue metrics: ",
      nextBlockNumber = blockDataQueue[0].blockNumber,
      blockDataQueueLen = blockDataQueue.len()
    info "Block offers queue metrics: ",
      nextBlockNumber = blockOffersQueue[0].blockNumber,
      blockOffersQueueLen = blockOffersQueue.len()

proc runState*(config: PortalBridgeConf) =
  let
    portalClient = newRpcClientConnect(config.portalRpcUrl)
    portalNodeId =
      try:
        (waitFor portalClient.portal_stateNodeInfo()).nodeId
      except CatchableError as e:
        fatal "Failed to connect to portal client", error = $e.msg
        quit QuitFailure
  info "Connected to portal client with nodeId", nodeId = portalNodeId

  let web3Client = newRpcClientConnect(config.web3UrlState)
  if web3Client of RpcHttpClient:
    warn "Using a WebSocket connection to the JSON-RPC API is recommended to improve performance"

  let db = DatabaseRef.init(config.stateDir.string).get()
  defer:
    db.close()

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

  let
    bufferSize = 1000
    blockDataQueue = newAsyncQueue[BlockData](bufferSize)
    blockOffersQueue = newAsyncQueue[BlockOffersRef](bufferSize)

  asyncSpawn runBackfillCollectBlockDataLoop(
    db, blockDataQueue, web3Client, config.startBlockNumber
  )
  asyncSpawn runBackfillBuildBlockOffersLoop(
    db, blockDataQueue, blockOffersQueue, config.verifyStateProofs, config.gossipGenesis
  )

  for workerId in 1 .. config.gossipWorkersCount.int:
    asyncSpawn runBackfillGossipBlockOffersLoop(
      blockOffersQueue, portalClient, portalNodeId, config.verifyGossip, workerId
    )

  asyncSpawn runBackfillMetricsLoop(blockDataQueue, blockOffersQueue)

  while true:
    poll()

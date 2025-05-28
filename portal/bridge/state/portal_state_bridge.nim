# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, algorithm, uri, strutils],
  chronicles,
  chronos,
  stint,
  json_serialization,
  stew/byteutils,
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[addresses_rlp, hashes_rlp],
  ../../../execution_chain/common/chain_config,
  ../../rpc/rpc_calls/rpc_trace_calls,
  ../../rpc/portal_rpc_client,
  ../../network/state/[state_content, state_gossip],
  ./[database, state_diff, world_state_helper, offers_builder],
  ../common/rpc_helpers,
  ../nimbus_portal_bridge_conf

logScope:
  topics = "portal_bridge"

type
  BlockData = object
    blockNumber: uint64
    blockHash: Hash32
    miner: EthAddress
    uncles: seq[tuple[miner: EthAddress, blockNumber: uint64]]
    parentStateRoot: Hash32
    stateRoot: Hash32
    stateDiffs: seq[TransactionDiff]

  BlockOffers = ref object
    blockNumber: uint64
    accountTrieOffers: seq[AccountTrieOfferWithKey]
    contractTrieOffers: seq[ContractTrieOfferWithKey]
    contractCodeOffers: seq[ContractCodeOfferWithKey]

  PortalStateGossipWorker = ref object
    id: int
    portalClients: OrderedTable[NodeId, RpcClient]
    portalEndpoints: seq[(JsonRpcUrl, NodeId)]
    blockOffersQueue: AsyncQueue[BlockOffers]
    gossipBlockOffersLoop: Future[void]

  PortalStateBridge* = ref object
    web3Client: RpcClient
    web3Url: JsonRpcUrl
    db: DatabaseRef
    blockDataQueue: AsyncQueue[BlockData]
    blockOffersQueue: AsyncQueue[BlockOffers]
    gossipWorkers: seq[PortalStateGossipWorker]
    collectBlockDataLoop: Future[void]
    buildBlockOffersLoop: Future[void]
    metricsLoop: Future[void]

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

proc runCollectBlockDataLoop(
    bridge: PortalStateBridge, startBlockNumber: uint64
) {.async: (raises: []).} =
  info "Starting collect block data loop"

  try:
    bridge.web3Client = newRpcClientConnect(bridge.web3Url)
    if bridge.web3Client of RpcHttpClient:
      warn "Using a WebSocket connection to the JSON-RPC API is recommended to improve performance"

    var
      parentStateRoot: Hash32
      currentBlockNumber = startBlockNumber

    while true:
      if currentBlockNumber mod 10000 == 0:
        info "Collecting block data for block number: ",
          blockNumber = currentBlockNumber

      let blockData = bridge.db.getBlockData(currentBlockNumber).valueOr:
        # block data doesn't exist in db so we fetch it via RPC

        # This should only be run for the starting block but we put this code here
        # so that we can reconnect to the the web3 client on failure and also delay
        # fetching data from the web3 client until needed
        if parentStateRoot == default(Hash32):
          doAssert(currentBlockNumber == startBlockNumber)

          # if we don't yet have the parent state root get it from the parent block
          let parentBlock = (
            await bridge.web3Client.getBlockByNumber(
              blockId(currentBlockNumber - 1.uint64), false
            )
          ).valueOr:
            error "Failed to get parent block", error = error
            await sleepAsync(3.seconds)
            # We might need to reconnect if using a WebSocket client
            await bridge.web3Client.tryReconnect(bridge.web3Url)
            continue

          parentStateRoot = parentBlock.stateRoot

        let
          blockId = blockId(currentBlockNumber)
          blockObject = (await bridge.web3Client.getBlockByNumber(blockId, false)).valueOr:
            error "Failed to get block", error = error
            await sleepAsync(3.seconds)
            # We might need to reconnect if using a WebSocket client
            await bridge.web3Client.tryReconnect(bridge.web3Url)
            continue
          stateDiffs = (await bridge.web3Client.getStateDiffsByBlockNumber(blockId)).valueOr:
            error "Failed to get state diffs", error = error
            await sleepAsync(3.seconds)
            continue

        var uncleBlocks: seq[BlockObject]
        for i in 0 .. blockObject.uncles.high:
          let uncleBlock = (
            await bridge.web3Client.getUncleByBlockNumberAndIndex(blockId, i.Quantity)
          ).valueOr:
            error "Failed to get uncle block", error = error
            await sleepAsync(3.seconds)
            continue
          uncleBlocks.add(uncleBlock)

        let blockData = BlockData(
          blockNumber: currentBlockNumber,
          blockHash: blockObject.hash,
          miner: blockObject.miner,
          uncles: uncleBlocks.mapIt((it.miner, it.number.uint64)),
          parentStateRoot: parentStateRoot,
          stateRoot: blockObject.stateRoot,
          stateDiffs: stateDiffs,
        )
        bridge.db.putBlockData(currentBlockNumber, blockData)

        blockData

      await bridge.blockDataQueue.addLast(blockData)
      parentStateRoot = blockData.stateRoot
      inc currentBlockNumber
  except CancelledError:
    trace "collectBlockDataLoop canceled"

proc runBuildBlockOffersLoop(
    bridge: PortalStateBridge,
    verifyStateProofs: bool,
    enableGossip: bool,
    gossipGenesis: bool,
) {.async: (raises: []).} =
  info "Starting build block offers loop"

  try:
    # wait for the first block data to be put on the queue
    # so that we can access the first block once available
    while bridge.blockDataQueue.empty():
      await sleepAsync(100.milliseconds)
    # peek but don't remove it so that it can be processed later
    let firstBlock = bridge.blockDataQueue[0]

    # Only apply genesis accounts if starting from block 1
    if firstBlock.blockNumber == 1:
      info "Building state for genesis"

      bridge.db.withTransaction:
        # Requires an active transaction because it writes an emptyRlp node
        # to the accounts HexaryTrie on initialization
        let
          worldState = WorldStateRef.init(bridge.db)
          genesisAccounts =
            try:
              genesisBlockForNetwork(MainNet).alloc
            except ValueError, RlpError:
              raiseAssert("Unable to get genesis accounts") # Should never happen
        worldState.applyGenesisAccounts(genesisAccounts)

        if enableGossip and gossipGenesis:
          let genesisBlockHash =
            hash32"d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"

          var builder = OffersBuilder.init(worldState, genesisBlockHash)
          builder.buildBlockOffers()

          await bridge.blockOffersQueue.addLast(
            BlockOffers(
              blockNumber: 0.uint64,
              accountTrieOffers: builder.getAccountTrieOffers(),
              contractTrieOffers: builder.getContractTrieOffers(),
              contractCodeOffers: builder.getContractCodeOffers(),
            )
          )

    # Load the world state using the parent state root
    let worldState = WorldStateRef.init(bridge.db, firstBlock.parentStateRoot)

    while true:
      let blockData = await bridge.blockDataQueue.popFirst()

      if blockData.blockNumber mod 10000 == 0:
        info "Building state for block number: ", blockNumber = blockData.blockNumber

      # For now all WorldStateRef functions need to be inside a transaction
      # because the DatabaseRef backends currently only supports reading and
      # writing to/from a single active transaction.
      bridge.db.withTransaction:
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

        if enableGossip:
          var builder = OffersBuilder.init(worldState, blockData.blockHash)
          builder.buildBlockOffers()

          await bridge.blockOffersQueue.addLast(
            BlockOffers(
              blockNumber: blockData.blockNumber,
              accountTrieOffers: builder.getAccountTrieOffers(),
              contractTrieOffers: builder.getContractTrieOffers(),
              contractCodeOffers: builder.getContractCodeOffers(),
            )
          )

      # After commit of the above db transaction which stores the updated account state
      # then we store the last persisted block number in the database so that we can use it
      # to enable restarting from this block if needed
      bridge.db.putLastPersistedBlockNumber(blockData.blockNumber)
  except CancelledError:
    trace "buildBlockOffersLoop canceled"

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

func buildOffersMap(blockOffers: BlockOffers): auto =
  let offersMap = newOrderedTable[seq[byte], seq[byte]]()

  for offerWithKey in blockOffers.accountTrieOffers:
    offersMap.recursiveCollectOffer(offerWithKey)
  for offerWithKey in blockOffers.contractTrieOffers:
    offersMap.recursiveCollectOffer(offerWithKey)
  for offerWithKey in blockOffers.contractCodeOffers:
    offersMap.collectOffer(offerWithKey)

  offersMap

proc orderPortalClientsByDistanceFromContent(
    worker: PortalStateGossipWorker, contentKey: seq[byte]
) =
  let contentId = ContentKeyByteList.init(contentKey).toContentId()

  # Closure to sort the portal clients using their nodeIds
  # and comparing them to the contentId to be gossipped
  proc portalClientsCmp(x, y: (NodeId, RpcClient)): int =
    let
      xDistance = contentId xor x[0]
      yDistance = contentId xor y[0]

    if xDistance == yDistance:
      0
    elif xDistance > yDistance:
      1
    else:
      -1

  # Sort the portalClients based on distance from the content so that
  # we gossip each piece of content to the closest node first
  worker.portalClients.sort(portalClientsCmp)

proc contentFoundInNetwork(
    worker: PortalStateGossipWorker, contentKey: seq[byte]
): Future[bool] {.async: (raises: [CancelledError]).} =
  for nodeId, client in worker.portalClients:
    try:
      let contentInfo = await client.portal_stateGetContent(contentKey.to0xHex())
      if contentInfo.content.len() > 0:
        trace "Found existing content in network",
          contentKey = contentKey.to0xHex(), nodeId, workerId = worker.id
        return true
    except CancelledError as e:
      raise e
    except CatchableError as e:
      debug "Unable to find existing content in network",
        contentKey = contentKey.to0xHex(), nodeId, error = e.msg, workerId = worker.id
  return false

proc gossipContentIntoNetwork(
    worker: PortalStateGossipWorker,
    minGossipPeers: int,
    contentKey: seq[byte],
    contentOffer: seq[byte],
): Future[bool] {.async: (raises: [CancelledError]).} =
  for nodeId, client in worker.portalClients:
    try:
      let
        putContentResult = await client.portal_statePutContent(
          contentKey.to0xHex(), contentOffer.to0xHex()
        )
        numPeers = putContentResult.peerCount
      if numPeers >= minGossipPeers:
        trace "Offer successfully gossipped to peers",
          contentKey = contentKey.to0xHex(), nodeId, numPeers, workerId = worker.id
        return true
      else:
        warn "Offer not gossiped to enough peers",
          contentKey = contentKey.to0xHex(), nodeId, numPeers, workerId = worker.id
    except CancelledError as e:
      raise e
    except CatchableError as e:
      error "Failed to gossip offer to peers",
        contentKey = contentKey.to0xHex(), nodeId, error = e.msg, workerId = worker.id
  return false

proc runGossipLoop(
    worker: PortalStateGossipWorker,
    verifyGossip: bool,
    skipGossipForExisting: bool,
    minGossipPeers: int,
) {.async: (raises: []).} =
  debug "Starting gossip block offers loop", workerId = worker.id

  try:
    # Create separate clients in each worker in order to improve performance.
    # WebSocket connections don't perform well when shared by many
    # concurrent workers.
    for (rpcUrl, nodeId) in worker.portalEndpoints:
      worker.portalClients[nodeId] = newRpcClientConnect(rpcUrl)

    var
      blockOffers = await worker.blockOffersQueue.popFirst()
      # A table of offer key, value pairs is used to filter out duplicates so
      # that we don't gossip the same offer multiple times.
      offersMap = buildOffersMap(blockOffers)

    while true:
      var retryGossip = false

      for contentKey, contentOffer in offersMap:
        worker.orderPortalClientsByDistanceFromContent(contentKey)

        # Check if we need to gossip the content
        if skipGossipForExisting and (await worker.contentFoundInNetwork(contentKey)):
          continue # move on to the next content key

        # Gossip the content into the network
        let gossipCompleted = await worker.gossipContentIntoNetwork(
          minGossipPeers, contentKey, contentOffer
        )
        if not gossipCompleted:
          # Retry gossip of this block
          retryGossip = true
          break

      # Check if the content can be found in the network
      var foundContentKeys = newSeq[seq[byte]]()
      if verifyGossip and not retryGossip:
        # Wait for the peers to be updated.
        # Wait time is proportional to the number of offers
        let waitTimeMs = 200 + (offersMap.len() * 20)
        await sleepAsync(waitTimeMs.milliseconds)

        for contentKey, _ in offersMap:
          worker.orderPortalClientsByDistanceFromContent(contentKey)

          if await worker.contentFoundInNetwork(contentKey):
            foundContentKeys.add(contentKey)
          else:
            # Retry gossip of this block
            retryGossip = true
            break

      # Retry if any failures occurred or if the content wasn't found in the network
      if retryGossip:
        await sleepAsync(5.seconds)

        # Don't retry gossip for content that was found in the network
        for key in foundContentKeys:
          offersMap.del(key)

        warn "Retrying state gossip for block: ",
          blockNumber = blockOffers.blockNumber,
          remainingOffers = offersMap.len(),
          workerId = worker.id

        # We might need to reconnect if using WebSocket clients
        for (rpcUrl, nodeId) in worker.portalEndpoints:
          await worker.portalClients.getOrDefault(nodeId).tryReconnect(rpcUrl)

        # Jump back to the top of while loop to retry processing the current block
        continue

      if blockOffers.blockNumber mod 1000 == 0:
        info "Finished gossiping offers for block: ",
          blockNumber = blockOffers.blockNumber,
          offerCount = offersMap.len(),
          workerId = worker.id
      else:
        debug "Finished gossiping offers for block: ",
          blockNumber = blockOffers.blockNumber,
          offerCount = offersMap.len(),
          workerId = worker.id

      blockOffers = await worker.blockOffersQueue.popFirst()
      offersMap = buildOffersMap(blockOffers)
  except CancelledError:
    trace "gossipBlockOffersLoop canceled"

proc runMetricsLoop(bridge: PortalStateBridge) {.async: (raises: []).} =
  info "Starting metrics loop"

  try:
    while true:
      await sleepAsync(30.seconds)

      if bridge.blockDataQueue.len() > 0:
        info "Block data queue metrics: ",
          nextBlockNumber = bridge.blockDataQueue[0].blockNumber,
          blockDataQueueLen = bridge.blockDataQueue.len()
      else:
        info "Block data queue metrics: ",
          blockDataQueueLen = bridge.blockDataQueue.len()

      if bridge.blockOffersQueue.len() > 0:
        info "Block offers queue metrics: ",
          nextBlockNumber = bridge.blockOffersQueue[0].blockNumber,
          blockOffersQueueLen = bridge.blockOffersQueue.len()
      else:
        info "Block offers queue metrics: ",
          blockOffersQueueLen = bridge.blockOffersQueue.len()
  except CancelledError:
    trace "metricsLoop canceled"

proc validatePortalRpcEndpoints(
    portalRpcUrl: JsonRpcUrl, numOfEndpoints: int
): Future[seq[(JsonRpcUrl, NodeId)]] {.async: (raises: []).} =
  var
    uri = parseUri(portalRpcUrl.value)
    endpoints = newSeq[(JsonRpcUrl, NodeId)]()

  for i in 0 ..< numOfEndpoints:
    let
      rpcUrl =
        try:
          JsonRpcUrl.parseCmdArg($uri)
        except ValueError as e:
          raiseAssert("Failed to parse JsonRpcUrl")
      client = newRpcClientConnect(rpcUrl)
      nodeId =
        try:
          (await client.portal_stateNodeInfo()).nodeId
        except CatchableError as e:
          fatal "Failed to connect to portal client", error = $e.msg
          quit QuitFailure
    info "Connected to portal client with nodeId", nodeId

    endpoints.add((rpcUrl, nodeId))
    uri.port =
      try:
        $(parseInt(uri.port) + 1)
      except ValueError as e:
        raiseAssert("Failed to parse int")

    asyncSpawn client.close() # this connection was only used to collect the nodeId

  return endpoints

proc validateStartBlockNumber(db: DatabaseRef, startBlockNumber: uint64) =
  let maybeLastPersistedBlock = db.getLastPersistedBlockNumber()
  if maybeLastPersistedBlock.isSome():
    info "Last persisted block found in the database: ",
      lastPersistedBlock = maybeLastPersistedBlock.get()
    if startBlockNumber < 1 or startBlockNumber > maybeLastPersistedBlock.get():
      warn "Start block must be set to a value between 1 and the last persisted block"
      quit QuitFailure
  else:
    info "No last persisted block found in the database"
    if startBlockNumber != 1:
      warn "Start block must be set to 1"
      quit QuitFailure

proc start*(bridge: PortalStateBridge, config: PortalBridgeConf) =
  info "Starting Portal state bridge from block: ",
    startBlockNumber = config.startBlockNumber

  bridge.collectBlockDataLoop = bridge.runCollectBlockDataLoop(config.startBlockNumber)
  bridge.buildBlockOffersLoop = bridge.runBuildBlockOffersLoop(
    config.verifyStateProofs, config.enableGossip, config.gossipGenesis
  )
  bridge.metricsLoop = bridge.runMetricsLoop()

  info "Starting concurrent gossip workers", workerCount = bridge.gossipWorkers.len()

  for worker in bridge.gossipWorkers:
    worker.gossipBlockOffersLoop = worker.runGossipLoop(
      config.verifyGossip, config.skipGossipForExisting, config.minGossipPeers.int
    )

  info "Portal state bridge started successfully. Running from block: ",
    startBlockNumber = config.startBlockNumber

proc stop*(bridge: PortalStateBridge) {.async: (raises: []).} =
  info "Stopping Portal state bridge"

  var futures = newSeq[Future[void]]()

  for worker in bridge.gossipWorkers:
    if not worker.gossipBlockOffersLoop.isNil():
      # No need to wait for these loops to stop as they don't touch the database
      worker.gossipBlockOffersLoop.cancelSoon()

  if not bridge.metricsLoop.isNil():
    futures.add(bridge.metricsLoop.cancelAndWait())
  if not bridge.buildBlockOffersLoop.isNil():
    futures.add(bridge.buildBlockOffersLoop.cancelAndWait())
  if not bridge.collectBlockDataLoop.isNil():
    futures.add(bridge.collectBlockDataLoop.cancelAndWait())

  await noCancel(allFutures(futures))

  # Close the database
  bridge.db.close()

  for worker in bridge.gossipWorkers:
    worker.gossipBlockOffersLoop = nil

  bridge.metricsLoop = nil
  bridge.buildBlockOffersLoop = nil
  bridge.collectBlockDataLoop = nil

proc runState*(
    config: PortalBridgeConf
): Future[PortalStateBridge] {.async: (raises: []).} =
  let portalEndpoints =
    await validatePortalRpcEndpoints(config.portalRpcUrl, config.portalRpcEndpoints.int)

  info "Using state directory: ", stateDir = config.stateDir.string
  let db = DatabaseRef.init(config.stateDir.string).get()

  validateStartBlockNumber(db, config.startBlockNumber)

  const queueSize = 1000
  let bridge = PortalStateBridge(
    web3Url: config.web3RpcUrl,
    db: db,
    blockDataQueue: newAsyncQueue[BlockData](queueSize),
    blockOffersQueue: newAsyncQueue[BlockOffers](queueSize),
    gossipWorkers: newSeq[PortalStateGossipWorker](),
  )

  for i in 0 ..< config.gossipWorkers.int:
    let worker = PortalStateGossipWorker(
      id: i + 1,
      portalEndpoints: portalEndpoints,
      blockOffersQueue: bridge.blockOffersQueue,
    )
    bridge.gossipWorkers.add(worker)

  bridge.start(config)

  return bridge

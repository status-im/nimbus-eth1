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
  # stew/byteutils,
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../../nimbus/common/chain_config,
  ../../common/common_utils,
  ../../rpc/rpc_calls/rpc_trace_calls,
  ../../network/state/state_content,
  ./state_bridge/[database, state_diff, world_state_helper, offers_builder],
  ./[portal_bridge_conf, portal_bridge_common]

type BlockDataRef = ref object
  blockNumber: uint64
  blockObject: BlockObject
  stateDiffs: seq[StateDiffRef]
  uncleBlocks: seq[BlockObject]

type BlockOffersRef = ref object
  blockNumber: uint64
  accountTrieOffers: seq[(AccountTrieNodeKey, AccountTrieNodeOffer)]
  contractTrieOffers: seq[(ContractTrieNodeKey, ContractTrieNodeOffer)]
  contractCodeOffers: seq[(ContractCodeKey, ContractCodeOffer)]

proc runBackfillCollectBlockDataLoop(
    blockDataQueue: AsyncQueue[BlockDataRef],
    web3Client: RpcClient,
    startBlockNumber: uint64,
) {.async: (raises: [CancelledError]).} =
  info "Starting state backfill collect block data loop"

  if web3Client of RpcHttpClient:
    warn "Using a WebSocket connection to the JSON-RPC API is recommended to improve performance"

  var currentBlockNumber = startBlockNumber

  while true:
    if currentBlockNumber mod 10000 == 0:
      info "Collecting block data for block number: ", blockNumber = currentBlockNumber

    let
      blockId = blockId(currentBlockNumber)
      blockRequest = web3Client.getBlockByNumber(blockId, false)
      stateDiffsRequest = web3Client.getStateDiffsByBlockNumber(blockId)

      blockObject = (await blockRequest).valueOr:
        error "Failed to get block", error
        await sleepAsync(1.seconds)
        continue

    var uncleBlockRequests: seq[Future[Result[BlockObject, string]]]
    for i in 0 .. blockObject.uncles.high:
      uncleBlockRequests.add(
        web3Client.getUncleByBlockNumberAndIndex(blockId, i.Quantity)
      )

    let stateDiffs = (await stateDiffsRequest).valueOr:
      error "Failed to get state diffs", error
      await sleepAsync(1.seconds)
      continue

    var uncleBlocks: seq[BlockObject]
    for uncleBlockRequest in uncleBlockRequests:
      try:
        let uncleBlock = (await uncleBlockRequest).valueOr:
          error "Failed to get uncle blocks", error
          await sleepAsync(1.seconds)
          break
        uncleBlocks.add(uncleBlock)
      except CatchableError as e:
        error "Failed to get uncleBlockRequest", error = e.msg
        break

    if uncleBlocks.len() < uncleBlockRequests.len():
      continue

    await blockDataQueue.addLast(
      BlockDataRef(
        blockNumber: currentBlockNumber,
        blockObject: blockObject,
        stateDiffs: stateDiffs,
        uncleBlocks: uncleBlocks,
      )
    )

    inc currentBlockNumber

proc runBackfillBuildBlockOffersLoop(
    blockDataQueue: AsyncQueue[BlockDataRef],
    blockOffersQueue: AsyncQueue[BlockOffersRef],
    stateDir: string,
) {.async: (raises: [CancelledError]).} =
  info "Starting state backfill build block offers loop"

  let db = DatabaseRef.init(stateDir).get()
  defer:
    db.close()

  let worldState = db.withTransaction:
    let
      # Requires an active transaction because it writes an emptyRlp node
      # to the accounts HexaryTrie on initialization
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

    ws

  while true:
    let blockData = await blockDataQueue.popFirst()

    if blockData.blockNumber mod 10000 == 0:
      info "Building state for block number: ", blockNumber = blockData.blockNumber

    # For now all WorldStateRef functions need to be inside a transaction
    # because the DatabaseRef currently only supports reading and writing to/from
    # a single active transaction.
    db.withTransaction:
      defer:
        worldState.clearPreimages()

      for stateDiff in blockData.stateDiffs:
        worldState.applyStateDiff(stateDiff)
      let
        minerData =
          (EthAddress(blockData.blockObject.miner), blockData.blockObject.number.uint64)
        uncleMinersData =
          blockData.uncleBlocks.mapIt((EthAddress(it.miner), it.number.uint64))
      worldState.applyBlockRewards(minerData, uncleMinersData)

      doAssert(blockData.blockObject.stateRoot.bytes() == worldState.stateRoot.data)
      trace "State diffs successfully applied to block number:",
        blockNumber = blockData.blockNumber

      var builder = OffersBuilderRef.init(
        worldState, KeccakHash.fromBytes(blockData.blockObject.hash.bytes())
      )
      builder.buildBlockOffers()

      await blockOffersQueue.addLast(
        BlockOffersRef(
          blockNumber: blockData.blockNumber,
          accountTrieOffers: builder.getAccountTrieOffers(),
          contractTrieOffers: builder.getContractTrieOffers(),
          contractCodeOffers: builder.getContractCodeOffers(),
        )
      )

proc runBackfillMetricsLoop(
    blockDataQueue: AsyncQueue[BlockDataRef],
    blockOffersQueue: AsyncQueue[BlockOffersRef],
) {.async: (raises: [CancelledError]).} =
  debug "Starting state backfill metrics loop"

  while true:
    await sleepAsync(10.seconds)
    info "Block data queue length: ", blockDataQueueLen = blockDataQueue.len()
    info "Block offers queue length: ", blockOffersQueueLen = blockOffersQueue.len()

proc runState*(config: PortalBridgeConf) =
  let
    #portalClient = newRpcClientConnect(config.portalRpcUrl)
    web3Client = newRpcClientConnect(config.web3UrlState)

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
    const
      startBlockNumber = 1
        # This will become a parameter in the config once we can support it
      bufferSize = 1000 # Should we make this configurable?

    info "Starting state backfill from block number: ", startBlockNumber

    let
      blockDataQueue = newAsyncQueue[BlockDataRef](bufferSize)
      blockOffersQueue = newAsyncQueue[BlockOffersRef](bufferSize)

    asyncSpawn runBackfillCollectBlockDataLoop(
      blockDataQueue, web3Client, startBlockNumber
    )

    asyncSpawn runBackfillBuildBlockOffersLoop(
      blockDataQueue, blockOffersQueue, config.stateDir.string
    )

    asyncSpawn runBackfillMetricsLoop(blockDataQueue, blockOffersQueue)

  while true:
    poll()

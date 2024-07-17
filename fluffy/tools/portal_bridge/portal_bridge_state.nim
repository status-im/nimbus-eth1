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
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../../nimbus/common/chain_config,
  ../../rpc/rpc_calls/rpc_trace_calls,
  ./state_bridge/[database, state_diff, world_state_helper],
  ./[portal_bridge_conf, portal_bridge_common]

type BlockData = object
  blockNumber: uint64
  blockObject: BlockObject
  stateDiffs: seq[StateDiffRef]
  uncleBlocks: seq[BlockObject]

proc runBackfillCollectBlockDataLoop(
    blockDataQueue: AsyncQueue[BlockData],
    web3Client: RpcClient,
    startBlockNumber: uint64,
) {.async: (raises: [CancelledError]).} =
  debug "Starting state backfill collect block data loop"

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

    let blockData = BlockData(
      blockNumber: currentBlockNumber,
      blockObject: blockObject,
      stateDiffs: stateDiffs,
      uncleBlocks: uncleBlocks,
    )
    await blockDataQueue.addLast(blockData)

    inc currentBlockNumber

proc runBackfillBuildStateLoop(
    blockDataQueue: AsyncQueue[BlockData], stateDir: string
) {.async: (raises: [CancelledError]).} =
  debug "Starting state backfill build state loop"

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
    ws

  while true:
    let blockData = await blockDataQueue.popFirst()

    if blockData.blockNumber mod 10000 == 0:
      info "Building state for block number: ", blockNumber = blockData.blockNumber

    db.withTransaction:
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

proc runBackfillMetricsLoop(
    blockDataQueue: AsyncQueue[BlockData]
) {.async: (raises: [CancelledError]).} =
  debug "Starting state backfill metrics loop"

  while true:
    await sleepAsync(10.seconds)
    info "Block data queue length: ", queueLen = blockDataQueue.len()

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
    const startBlockNumber = 1
      # This will become a parameter in the config once we can support it
    info "Starting state backfill from block number: ", startBlockNumber

    const bufferSize = 1000 # Should we make this configurable?
    let blockDataQueue = newAsyncQueue[BlockData](bufferSize)

    asyncSpawn runBackfillCollectBlockDataLoop(
      blockDataQueue, web3Client, startBlockNumber
    )

    asyncSpawn runBackfillBuildStateLoop(blockDataQueue, config.stateDir.string)

    asyncSpawn runBackfillMetricsLoop(blockDataQueue)

  while true:
    poll()

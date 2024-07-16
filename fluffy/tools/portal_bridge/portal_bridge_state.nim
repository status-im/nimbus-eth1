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
  stint,
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../../nimbus/common/chain_config,
  ../../rpc/rpc_calls/rpc_trace_calls,
  ./state_bridge/[database, state_diff, world_state_helper],
  ./[portal_bridge_conf, portal_bridge_common]

proc runBackfillLoop(
    #portalClient: RpcClient,
    web3Client: RpcClient,
    stateDir: string, #startBlockNumber: uint64,
) {.async: (raises: [CancelledError]).} =
  try:
    let db = DatabaseRef.init(stateDir).get()
    defer:
      db.close()

    let worldState = db.withTransaction:
      let
        # Requires an active transaction because it writes an emptyRlp node
        # to tries on initialization
        ws = WorldStateRef.init(db)
        genesisAccounts = genesisBlockForNetwork(MainNet).alloc
      ws.applyGenesisAccounts(genesisAccounts)
      ws

    let startBlockNumber: uint64 = 1
    info "Starting from block number: ", startBlockNumber
    var currentBlockNumber = startBlockNumber

    while true:
      let
        blockNumRequest =
          web3Client.getBlockByNumber(blockId(currentBlockNumber), false)
        stateDiffsRequest =
          web3Client.getStateDiffsByBlockNumber(blockId(currentBlockNumber))

        blockObject = (await blockNumRequest).valueOr:
          error "Failed to get block", error
          await sleepAsync(1.seconds)
          continue

      var uncleBlocks: seq[BlockObject]
      for i in 0 .. blockObject.uncles.high:
        let uncleBlock = (
          await web3Client.getUncleByBlockNumberAndIndex(
            blockId(currentBlockNumber), i.Quantity
          )
        ).valueOr:
          error "Failed to get uncle block", error
          await sleepAsync(1.seconds)
          continue
        uncleBlocks.add(uncleBlock)

      let stateDiffs = (await stateDiffsRequest).valueOr:
        error "Failed to get state diff", error
        await sleepAsync(1.seconds)
        continue

      if currentBlockNumber mod 5000 == 0:
        echo "Current block number: ", currentBlockNumber

      # if currentBlockNumber == 50111:
      #   echo "stateDiffs.balances: ", stateDiffs[0].balances
      #   echo "stateDiffs.nonces: ", stateDiffs[0].nonces
      #   echo "stateDiffs.storage: ", stateDiffs[0].storage
      #   echo "stateDiffs.codes: ", stateDiffs[0].code

      db.withTransaction:
        for stateDiff in stateDiffs:
          worldState.applyStateDiff(stateDiff)
        let
          blockData = (EthAddress(blockObject.miner), blockObject.number.uint64)
          uncleBlocksData = uncleBlocks.mapIt((EthAddress(it.miner), it.number.uint64))
        worldState.applyBlockRewards(blockData, uncleBlocksData)

      doAssert(blockObject.stateRoot.bytes() == worldState.stateRoot.data)

      inc currentBlockNumber
  except CatchableError as e:
    error "runBackfillLoop failed: ", error = e.msg

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
    asyncSpawn runBackfillLoop(
      web3Client, config.stateDir.string #, config.startBlockNumber
    )

  while true:
    poll()

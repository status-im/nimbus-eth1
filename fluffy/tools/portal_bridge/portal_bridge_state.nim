# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  stint,
  eth/[common, trie, trie/db],
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../rpc/rpc_calls/rpc_trace_calls,
  ../../../nimbus/common/chain_config,
  ./state_bridge/[state_diff, world_state],
  ./[portal_bridge_conf, portal_bridge_common]

# For now just using in-memory state tries
# To-Do: Use RocksDb as the db backend
# To-Do: Use location based trie implementation where path is used
# instead of node hash is used as key for each value in the trie.
proc applyGenesisAccounts*(
    worldState: WorldStateRef, alloc: GenesisAlloc
) {.raises: [RlpError].} =
  for address, genAccount in alloc:
    var accState = worldState.getAccount(address)

    accState.setBalance(genAccount.balance)
    accState.setNonce(genAccount.nonce)

    if genAccount.code.len() > 0:
      for slotKey, slotValue in genAccount.storage:
        accState.setStorage(slotKey, slotValue)
      accState.setCode(genAccount.code)

    worldState.setAccount(address, accState)

proc applyStateDiff(
    worldState: WorldStateRef, stateDiff: StateDiffRef
) {.raises: [RlpError].} =
  for address, balanceDiff in stateDiff.balances:
    let
      nonceDiff = stateDiff.nonces.getOrDefault(address)
      codeDiff = stateDiff.code.getOrDefault(address)
      storageDiff = stateDiff.storage.getOrDefault(address)

    var
      deleteAccount = false
      accState = worldState.getAccount(address)

    if balanceDiff.kind == create or balanceDiff.kind == update:
      accState.setBalance(balanceDiff.after)
    elif balanceDiff.kind == delete:
      deleteAccount = true

    if nonceDiff.kind == create or nonceDiff.kind == update:
      accState.setNonce(nonceDiff.after)
    elif nonceDiff.kind == delete:
      doAssert deleteAccount == true

    if codeDiff.kind == create or codeDiff.kind == update:
      accState.setCode(codeDiff.after)
    elif codeDiff.kind == delete:
      doAssert deleteAccount == true

    for slotKey, slotDiff in storageDiff:
      if slotDiff.kind == create or slotDiff.kind == update:
        if slotDiff.after == 0:
          accState.deleteStorage(slotKey)
        else:
          accState.setStorage(slotKey, slotDiff.after)
      elif slotDiff.kind == delete:
        accState.deleteStorage(slotKey)

    if deleteAccount:
      worldState.deleteAccount(address)
    else:
      worldState.setAccount(address, accState)

proc applyBlockRewards(
    worldState: WorldStateRef,
    blockObject: BlockObject,
    uncleBlocks: openArray[BlockObject],
) {.raises: [RlpError].} =
  const baseReward = u256(5) * pow(u256(10), 18)

  block:
    # calculate block miner reward
    let
      minerAddress = EthAddress(blockObject.miner)
      uncleInclusionReward = (baseReward shr 5) * u256(uncleBlocks.len())

    var accState = worldState.getAccount(minerAddress)
    accState.addBalance(baseReward + uncleInclusionReward)
    worldState.setAccount(minerAddress, accState)

  # calculate uncle miners rewards
  for i, uncleBlock in uncleBlocks:
    let
      uncleMinerAddress = EthAddress(uncleBlock.miner)
      uncleReward =
        (u256(8 + uint64(uncleBlock.number) - uint64(blockObject.number)) * baseReward) shr
        3
    var accState = worldState.getAccount(uncleMinerAddress)
    accState.addBalance(uncleReward)
    worldState.setAccount(uncleMinerAddress, accState)

proc runBackfillLoop(
    #portalClient: RpcClient,
    web3Client: RpcClient,
    startBlockNumber: uint64,
) {.async: (raises: [CancelledError]).} =
  try:
    let
      worldState = WorldStateRef.init(newMemoryDB())
      genesisAccounts = genesisBlockForNetwork(MainNet).alloc
    applyGenesisAccounts(worldState, genesisAccounts)

    # for now we can only start from block 1 because the state is only in memory
    var currentBlockNumber: uint64 = 1
    echo "Starting from block number: ", currentBlockNumber

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

      for stateDiff in stateDiffs:
        applyStateDiff(worldState, stateDiff)
      applyBlockRewards(worldState, blockObject, uncleBlocks)

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
    asyncSpawn runBackfillLoop(web3Client, config.startBlockNumber)

  while true:
    poll()

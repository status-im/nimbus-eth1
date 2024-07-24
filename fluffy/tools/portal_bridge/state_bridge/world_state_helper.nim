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
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../../../nimbus/common/chain_config,
  ./[state_diff, world_state]

export chain_config, state_diff, world_state

proc applyGenesisAccounts*(worldState: WorldStateRef, alloc: GenesisAlloc) =
  for address, genAccount in alloc:
    var accState = worldState.getAccount(address)

    accState.setBalance(genAccount.balance)
    accState.setNonce(genAccount.nonce)

    if genAccount.code.len() > 0:
      for slotKey, slotValue in genAccount.storage:
        accState.setStorage(slotKey, slotValue)
      accState.setCode(genAccount.code)

    worldState.setAccount(address, accState)

proc applyStateDiff*(worldState: WorldStateRef, txDiff: TransactionDiff) =
  for accountDiff in txDiff:
    let
      address = accountDiff.address
      balanceDiff = accountDiff.balanceDiff
      nonceDiff = accountDiff.nonceDiff
      codeDiff = accountDiff.codeDiff
      storageDiff = accountDiff.storageDiff

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

    if codeDiff.kind == create and codeDiff.after.len() > 0:
      accState.setCode(codeDiff.after)
    elif codeDiff.kind == update:
      accState.setCode(codeDiff.after)
    elif codeDiff.kind == delete:
      doAssert deleteAccount == true

    for (slotKey, slotValueDiff) in storageDiff:
      if slotValueDiff.kind == create or slotValueDiff.kind == update:
        if slotValueDiff.after == 0:
          accState.deleteStorage(slotKey)
        else:
          accState.setStorage(slotKey, slotValueDiff.after)
      elif slotValueDiff.kind == delete:
        accState.deleteStorage(slotKey)

    if deleteAccount:
      worldState.deleteAccount(address)
    else:
      worldState.setAccount(address, accState)

proc applyBlockRewards*(
    worldState: WorldStateRef,
    minerData: tuple[miner: EthAddress, blockNumber: uint64],
    uncleMinersData: openArray[tuple[miner: EthAddress, blockNumber: uint64]],
) =
  const baseReward = u256(5) * pow(u256(10), 18)

  block:
    # calculate block miner reward
    let
      minerAddress = EthAddress(minerData.miner)
      uncleInclusionReward = (baseReward shr 5) * u256(uncleMinersData.len())

    var accState = worldState.getAccount(minerAddress)
    accState.addBalance(baseReward + uncleInclusionReward)
    worldState.setAccount(minerAddress, accState)

  # calculate uncle miners rewards
  for i, uncleMinerData in uncleMinersData:
    let
      uncleMinerAddress = EthAddress(uncleMinerData.miner)
      uncleReward =
        (u256(8 + uncleMinerData.blockNumber - minerData.blockNumber) * baseReward) shr 3
    var accState = worldState.getAccount(uncleMinerAddress)
    accState.addBalance(uncleReward)
    worldState.setAccount(uncleMinerAddress, accState)

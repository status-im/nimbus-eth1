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
  eth/common/addresses,
  ../../../../nimbus/common/chain_config,
  ./[state_diff, world_state]

from ../../../../nimbus/core/dao import DAORefundContract, DAODrainList

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

    if codeDiff.kind == create or codeDiff.kind == update:
      accState.setCode(codeDiff.after)

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
    minerData: tuple[miner: Address, blockNumber: uint64],
    uncleMinersData: openArray[tuple[miner: Address, blockNumber: uint64]],
) =
  const baseReward = u256(5) * pow(u256(10), 18)

  block:
    # calculate block miner reward
    let uncleInclusionReward = (baseReward shr 5) * u256(uncleMinersData.len())
    var accState = worldState.getAccount(minerData.miner)
    accState.addBalance(baseReward + uncleInclusionReward)
    worldState.setAccount(minerData.miner, accState)

  # calculate uncle miners rewards
  for i, uncleMinerData in uncleMinersData:
    let uncleReward =
      (u256(8 + uncleMinerData.blockNumber - minerData.blockNumber) * baseReward) shr 3
    var accState = worldState.getAccount(uncleMinerData.miner)
    accState.addBalance(uncleReward)
    worldState.setAccount(uncleMinerData.miner, accState)

# ApplyDAOHardFork modifies the state database according to the DAO hard-fork
# rules, transferring all balances of a set of DAO accounts to a single refund
# contract.
proc applyDAOHardFork*(worldState: WorldStateRef) =
  # Move every DAO account and extra-balance account funds into the refund contract
  var toAccount = worldState.getAccount(DAORefundContract)

  for address in DAODrainList:
    var fromAccount = worldState.getAccount(address)
    toAccount.addBalance(fromAccount.getBalance())
    fromAccount.setBalance(0.u256)
    worldState.setAccount(address, fromAccount)

  worldState.setAccount(DAORefundContract, toAccount)

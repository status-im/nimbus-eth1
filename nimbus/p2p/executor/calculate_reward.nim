# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../db/accounts_cache,
  ../../forks,
  ../../vm_state,
  ../../vm_types,
  ./executor_helpers,
  eth/common


func eth(n: int): UInt256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

const
  eth5 = 5.eth
  eth3 = 3.eth
  eth2 = 2.eth
  eth0 = 0.u256

  # Note than the `blockRewards` were previously exported but nowhere
  # used otherwise.
  blockRewards: array[Fork, UInt256] = [
    eth5, # FkFrontier
    eth5, # FkHomestead
    eth5, # FkTangerine
    eth5, # FkSpurious
    eth3, # FkByzantium
    eth2, # FkConstantinople
    eth2, # FkPetersburg
    eth2, # FkIstanbul
    eth2, # FkBerlin
    eth2  # FkLondon
   ]

{.push raises: [Defect].}


proc calculateReward*(vmState: BaseVMState; account: EthAddress;
                      number: BlockNumber; uncles: openArray[BlockHeader])
    {.gcsafe, raises: [Defect,CatchableError].} =

  var blockReward: UInt256
  safeExecutor("getFork"):
    blockReward = blockRewards[vmState.getForkUnsafe]

  var mainReward = blockReward

  for uncle in uncles:
    var uncleReward = uncle.blockNumber.u256 + 8.u256
    uncleReward -= number
    uncleReward = uncleReward * blockReward
    uncleReward = uncleReward div 8.u256
    vmState.mutateStateDB:
      db.addBalance(uncle.coinbase, uncleReward)
    mainReward += blockReward div 32.u256

  vmState.mutateStateDB:
    db.addBalance(account, mainReward)


proc calculateReward*(vmState: BaseVMState;
                      header: BlockHeader; body: BlockBody)
    {.gcsafe, raises: [Defect,CatchableError].} =
  vmState.calculateReward(header.coinbase, header.blockNumber, body.uncles)

# End

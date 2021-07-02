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
  eth/common


func eth(n: int): Uint256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

const
  eth5 = 5.eth
  eth3 = 3.eth
  eth2 = 2.eth
  blockRewards*: array[Fork, Uint256] = [
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

proc calculateReward*(vmState: BaseVMState;
                      fork: Fork; header: BlockHeader; body: BlockBody) =
  let blockReward = blockRewards[fork]
  var mainReward = blockReward

  for uncle in body.uncles:
    var uncleReward = uncle.blockNumber.u256 + 8.u256
    uncleReward -= header.blockNumber.u256
    uncleReward = uncleReward * blockReward
    uncleReward = uncleReward div 8.u256
    vmState.mutateStateDB:
      db.addBalance(uncle.coinbase, uncleReward)
    mainReward += blockReward div 32.u256

  vmState.mutateStateDB:
    db.addBalance(header.coinbase, mainReward)

# End

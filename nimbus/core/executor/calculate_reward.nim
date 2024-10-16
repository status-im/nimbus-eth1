# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  stint,
  ../../common/evmforks,
  eth/common/headers,
  ../../db/ledger,
  ../../evm/state,
  ../../evm/types

{.push raises: [].}

# ------------------------------------------------------------------------------
# Block reward helpers
# ------------------------------------------------------------------------------

func eth(n: int): UInt256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

const
  eth5 = 5.eth
  eth3 = 3.eth
  eth2 = 2.eth
  eth0 = 0.u256

  BlockRewards: array[EVMFork, UInt256] = [
    eth5, # Frontier
    eth5, # Homestead
    eth5, # Tangerine
    eth5, # Spurious
    eth3, # Byzantium
    eth2, # Constantinople
    eth2, # Petersburg
    eth2, # Istanbul
    eth2, # Berlin
    eth2, # London
    eth0, # Paris
    eth0, # Shanghai
    eth0, # Cancun
    eth0, # Prague
  ]

proc calculateReward*(vmState: BaseVMState; account: Address;
                      number: BlockNumber; uncles: openArray[Header]) =
  let blockReward = BlockRewards[vmState.fork]
  var mainReward = blockReward

  for uncle in uncles:
    var uncleReward = uncle.number.u256 + 8.u256
    uncleReward -= number.u256
    uncleReward = uncleReward * blockReward
    uncleReward = uncleReward div 8.u256
    vmState.mutateStateDB:
      db.addBalance(uncle.coinbase, uncleReward)
    mainReward += blockReward div 32.u256

  vmState.mutateStateDB:
    db.addBalance(account, mainReward)


proc calculateReward*(vmState: BaseVMState;
                      header: Header; uncles: openArray[Header]) =
  vmState.calculateReward(header.coinbase, header.number, uncles)

# End

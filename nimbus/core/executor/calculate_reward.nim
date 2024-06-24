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
  ../../db/ledger,
  ../../common/common,
  ../../evm/state,
  ../../evm/types

{.push raises: [].}

proc calculateReward*(vmState: BaseVMState; account: EthAddress;
                      number: BlockNumber; uncles: openArray[BlockHeader]) =
  let blockReward = vmState.com.blockReward()
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
                      header: BlockHeader; uncles: openArray[BlockHeader]) =
  vmState.calculateReward(header.coinbase, header.number, uncles)

# End

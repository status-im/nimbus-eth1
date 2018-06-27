# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth_common/eth_types,
  ../../../logging, ../../../constants, ../../../errors,
  ../../../block_types,
  ../../../vm/[base, stack], ../../../db/db_chain,  ../../../utils/header,
  ./frontier_block, ./frontier_vm_state, ./frontier_validation

type
  FrontierVM* = ref object of VM

method name*(vm: FrontierVM): string =
  "FrontierVM"

method getBlockReward(vm: FrontierVM): UInt256 =
  BLOCK_REWARD

method getUncleReward(vm: FrontierVM, blockNumber: BlockNumber, uncle: Block): UInt256 =
  BLOCK_REWARD * (UNCLE_DEPTH_PENALTY_FACTOR + uncle.blockNumber - blockNumber) div UNCLE_DEPTH_PENALTY_FACTOR


method getNephewReward(vm: FrontierVM): UInt256 =
  vm.getBlockReward() div 32

proc newFrontierVM*(header: BlockHeader, chainDB: BaseChainDB): FrontierVM =
  new(result)
  result.chainDB = chainDB
  result.isStateless = true
  result.state = newFrontierVMState()
  result.state.chaindb = result.chainDB
  result.state.blockHeader = header
  result.`block` = makeFrontierBlock(header, @[])

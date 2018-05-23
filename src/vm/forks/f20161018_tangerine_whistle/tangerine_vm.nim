# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../../../logging, ../../../constants, ../../../errors,
  stint,
  ../../../block_types,
  ../../../vm/[base, stack], ../../../db/db_chain,  ../../../utils/header,
  ./Tangerine_block, ./Tangerine_vm_state, ./Tangerine_validation


type
  TangerineVM* = ref object of VM

method name*(vm: TangerineVM): string =
  "TangerineVM"

method getBlockReward(vm: TangerineVM): UInt256 =
  BLOCK_REWARD

method getUncleReward(vm: TangerineVM, blockNumber: UInt256, uncle: Block): UInt256 =
  BLOCK_REWARD * (UNCLE_DEPTH_PENALTY_FACTOR + uncle.blockNumber - blockNumber) div UNCLE_DEPTH_PENALTY_FACTOR


method getNephewReward(vm: TangerineVM): UInt256 =
  vm.getBlockReward() div 32

proc newTangerineVM*(header: BlockHeader, chainDB: BaseChainDB): TangerineVM =
  new(result)
  result.chainDB = chainDB
  result.isStateless = true
  result.state = newTangerineVMState()
  result.`block` = makeTangerineBlock(header, @[])

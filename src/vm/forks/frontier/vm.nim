import
  logging, constants, errors, ttmath, "block", vm / [base, stack], db / db_chain,  utils / header,
  frontier_block, frontier_vm_state, frontier_validation


type 
  FrontierVM* = ref object of VM

method name*(vm: FrontierVM): string =
  "FrontierVM"

method getBlockReward(vm: FrontierVM): UInt256 =
  BLOCK_REWARD

method getUncleReward(vm: FrontierVM, blockNumber: UInt256, uncle: Block): UInt256 =
  BLOCK_REWARD * (UNCLE_DEPTH_PENALTY_FACTOR + uncle.blockNumber - blockNumber) div UNCLE_DEPTH_PENALTY_FACTOR


method getNephewReward(vm: FrontierVM): UInt256 =
  vm.getBlockReward() div 32

proc newFrontierVM*(header: Header, chainDB: BaseChainDB): FrontierVM =
  new(result)
  result.chainDB = chainDB
  result.isStateless = true
  result.state = newFrontierVMState()

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../logging, ../constants, ../errors, ../transaction, ../vm_types, ../computation, ../block_types, ../vm_state, ../vm_state_transactions, ../db/db_chain, ../utils/header

type
  VMkind* = enum
    ## List of VMs forks (py-evm vm_class) of the Ethereum network
    # TODO: used in Chain.vmsByRange: can we store the runtimetime in a seq/tuple instead?
    vmkFrontier, vmkHomestead, vmkTangerineWhistle, vmkSpuriousDragon, vmkByzantium

  VM* = ref object of RootObj
    # The VM class represents the Chain rules for a specific protocol definition
    # such as the Frontier or Homestead network.  Defining an Chain  defining
    # individual VM classes for each fork of the protocol rules within that
    # network

    chainDB*: BaseChainDB
    isStateless*: bool
    state*: BaseVMState
    `block`*: Block

# TODO - Refactoring: superseded by newNimbusVM for the time being #https://github.com/status-im/nimbus/pull/37

# proc newVM*(header: BlockHeader, chainDB: BaseChainDB): VM =
#   new(result)
#   result.chainDB = chainDB

method name*(vm: VM): string =
  "VM"

method addTransaction*(vm: var VM, transaction: BaseTransaction, computation: BaseComputation): Block =
  # Add a transaction to the given block and save the block data into chaindb
  # var receipt = vm.state.makeReceipt(transaction, computation)
  # var transactionIdx = len(vm.`block`.transactions)
  # TODO
  return Block()

method applyTransaction*(vm: var VM, transaction: BaseTransaction): (BaseComputation, Block) =
  #  Apply the transaction to the vm in the current block
  if vm.isStateless:
    var (computation, b, trieData) = vm.state.applyTransaction(
      transaction,
      vm.`block`,
      isStateless=true)
    vm.`block` = b
    result = (computation, b)
    # Persist changed transaction and receipt key-values to self.chaindb.
  else:
    var (computation, _, _) = vm.state.applyTransaction(
      transaction,
      vm.`block`,
      isStateless=false)
    discard vm.addTransaction(transaction, computation)

    result = (computation, vm.`block`)


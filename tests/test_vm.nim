# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, stint,
  ./test_helpers, ./fixtures,
  ../src/[db/backends/memory_backend, db/state_db, chain, constants, utils/hexadecimal, vm_state],
  ../src/[vm/base, computation]

import typetraits

suite "VM":
  test "Apply transaction with no validation":
    var
      chain = chainWithoutBlockValidation()
      vm = chain.getVM()
      # txIdx = len(vm.`block`.transactions) # Can't take len of a runtime field
    let
      recipient = decodeHex("0xa94f5374fce5edbc8e2a8697c15331677e6ebf0c")
      amount = 100.u256
      ethaddr_from = chain.fundedAddress
      tx = newTransaction(vm, ethaddr_from, recipient, amount, chain.fundedAddressPrivateKey)
      # (computation, _) = vm.applyTransaction(tx)
      # accessLogs = computation.vmState.accessLogs

    # check(not computation.isError)

    let
      txGas = tx.gasPrice * constants.GAS_TX
      state_db = vm.state.readOnlyStateDB
      b = vm.`block`

    echo state_db.getBalance(ethaddr_from).type.name

    # check:
    #   state_db.getBalance(ethaddr_from) == chain.fundedAddressInitialBalance - amount - txGas # TODO: this really should be i256
    #   state_db.getBalance(recipient) == amount
    #   b.transactions[txIdx] == tx
    #   b.header.gasUsed == constants.GAS_TX


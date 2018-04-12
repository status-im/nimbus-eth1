# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest,
  ./test_helpers, ./fixtures,
  ../src/[db/backends/memory_backend, chain, constants, utils/hexadecimal]

suite "VM":
  test "Sanity check with no validation":
    var
      chain = chainWithoutBlockValidation()
      vm = chain.getVM()
      txIdx = len(vm.`block`.transactions)
      recipient = decodeHex("0xa94f5374fce5edbc8e2a8697c15331677e6ebf0c")
      amount = 100.Int256

    var ethaddr_from = chain.fundedAddress
    var tx = newTransaction(vm, ethaddr_from, recipient, amount, chain.fundedAddressPrivateKey)
    var (computation, _) = vm.applyTransaction(tx)
    var accessLogs = computation.vmState.accessLogs

    check(not computation.isError)

    var txGas = tx.gasPrice * constants.GAS_TX
    inDb(vm.state.stateDb(readOnly=true)):
      check(db.getBalance(ethaddr_from) == chain.fundedAddressInitialBalance - amount - txGas)
      check(db.getBalance(recipient) == amount)
    var b = vm.`block`
    check(b.transactions[txIdx] == tx)
    check(b.header.gasUsed == constants.GAS_TX)


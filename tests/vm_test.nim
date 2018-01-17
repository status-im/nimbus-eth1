import
  unittest,
  helpers, .. / src / [db / backends / memory, db / chain, constants, utils / hexadecimal]

suite "vm":
  test "apply no validation":
    var
      chain = testChain()
      vm = chain.getVM()
      txIdx = len(vm.`block`.transactions)
      recipient = decodeHex("0xa94f5374fce5edbc8e2a8697c15331677e6ebf0c")
      amount = 100.Int256
    
    var from = chain.fundedAddress
    var tx = newTransaction(vm, from, recipient, amount, chain.fundedAddressPrivateKey)
    var (computation, _) = vm.applyTransaction(tx)
    var accessLogs = computation.vmState.accessLogs
    
    check(not computation.isError)

    var txGas = tx.gasPrice * constants.GAS_TX
    inDb(vm.state.stateDb(readOnly=true)):
      check(db.getBalance(from) == chain.fundedAddressInitialBalance - amount - txGas)
      check(db.getBalance(recipient) == amount)
    var b = vm.`block`
    check(b.transactions[txIdx] == tx)
    check(b.header.gasUsed == constants.GAS_TX)


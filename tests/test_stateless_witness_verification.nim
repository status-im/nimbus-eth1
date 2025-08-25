# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  stew/byteutils,
  unittest2,
  ../execution_chain/common/common,
  ../execution_chain/stateless/[witness_generation, witness_verification]

suite "Stateless: Witness Verification":
  setup:
    let
      memDB = newCoreDbRef DefaultDbMemory
      ledger = LedgerRef.init(memDB.baseTxFrame(), false, collectWitness = true)
      code = hexToSeqByte("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
      addr1 = address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6"
      addr2 = address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec7"
      slot1 = 1.u256
      slot2 = 2.u256
      slot3 = 3.u256

    ledger.setBalance(addr1, 10.u256)
    ledger.setCode(addr1, code)
    ledger.setBalance(addr2, 20.u256)
    ledger.setStorage(addr1, slot1, 100.u256)
    ledger.setStorage(addr1, slot2, 200.u256)
    ledger.setStorage(addr1, slot3, 300.u256)
    ledger.persist(clearWitness = true)

    let
      stateRoot = ledger.getStateRoot()
      header1 = Header(number: 1)
      header2 = Header(number: 2, parentHash: header1.computeRlpHash())
      header3 = Header(number: 3, parentHash: header2.computeRlpHash(), stateRoot: stateRoot)

    ledger.txFrame.persistHeader(header1.computeRlpHash(), header1).expect("success")
    ledger.txFrame.persistHeader(header2.computeRlpHash(), header2).expect("success")
    ledger.txFrame.persistHeader(header3.computeRlpHash(), header3).expect("success")


  test "Build and verify execution witness":
    discard ledger.getBalance(addr1)
    discard ledger.getCode(addr1)
    discard ledger.getStorage(addr1, slot1)
    discard ledger.getStorage(addr1, slot2)
    discard ledger.getStorage(addr1, slot3)
    discard ledger.getStorage(addr1, 4.u256) # doesn't exist in the state
    discard ledger.getBalance(addr2)
    discard ledger.getStorage(addr2, 1.u256) # doesn't exist in the state
    discard ledger.getBalance(address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec8") # doesn't exist in the state

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 8

    var witness = Witness.build(witnessKeys, ledger)
    witness.addHeaderHash(header1.computeRlpHash())
    witness.addHeaderHash(header2.computeRlpHash())
    witness.addHeaderHash(header3.computeRlpHash())
    check witness.validateKeys(witnessKeys).isOk()

    let
      executionWitness = ExecutionWitness.build(witness, ledger)
      verificationResult = executionWitness.verify(stateRoot)
    check verificationResult.isOk()

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
  ../execution_chain/stateless/witness_generation

suite "Stateless: Witness Generation":
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


  test "Get account":
    discard ledger.getBalance(addr1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 1

    let witness = Witness.build(witnessKeys, ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 1
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))

  test "Get code":
    discard ledger.getCode(addr1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 1

    let witness = Witness.build(witnessKeys, ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 1
      witness.codeHashes.len() == 1
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))

  test "Set storage":
    ledger.setStorage(addr1, slot1, 20.u256)
    ledger.persist()

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    let witness = Witness.build(witnessKeys, ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))

  test "Get storage":
    discard ledger.getStorage(addr1, slot1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    let witness = Witness.build(witnessKeys, ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))

  test "Get committed storage":
    discard ledger.getCommittedStorage(addr1, slot1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    let witness = Witness.build(witnessKeys, ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))

  test "Get code and storage slots":
    discard ledger.getCode(addr1)
    discard ledger.getStorage(addr1, slot1)
    discard ledger.getStorage(addr1, slot2)
    discard ledger.getStorage(addr1, slot3)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 4

    let witness = Witness.build(witnessKeys, ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 4
      witness.codeHashes.len() == 1
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot2)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot3)))

  test "Order of keys":
    var witnessKeys: WitnessTable
    witnessKeys[(addr1, Opt.none(UInt256))] = true
    witnessKeys[(addr1, Opt.some(slot1))] = false
    witnessKeys[(addr2, Opt.none(UInt256))] = false
    witnessKeys[(addr1, Opt.some(slot2))] = false
    witnessKeys[(addr1, Opt.some(slot3))] = false
    check witnessKeys.len() == 5

    let witness = Witness.build(witnessKeys, ledger)

    check:
      witness.keys.len() == 5
      witness.keys[0] == addr1.data()
      witness.keys[1] == slot1.toBytesBE()
      witness.keys[2] == slot2.toBytesBE()
      witness.keys[3] == slot3.toBytesBE()
      witness.keys[4] == addr2.data()

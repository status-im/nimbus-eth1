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
  chronicles,
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
      slot1 = 1.u256
      slot2 = 2.u256
      slot3 = 3.u256

  test "Get account":
    ledger.setBalance(addr1, 10.u256)
    ledger.persist(clearWitness = true)

    discard ledger.getBalance(addr1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 1

    var codes: seq[seq[byte]]
    let witness = Witness.build(ledger, codes)

    check:
      witness.state.len() > 0
      witness.keys.len() == 1
      witness.codeHashes.len() == 0
      codes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))

  test "Get code":
    ledger.setCode(addr1, code)
    ledger.persist(clearWitness = true)

    discard ledger.getCode(addr1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 1

    var codes: seq[seq[byte]]
    let witness = Witness.build(ledger, codes)

    check:
      witness.state.len() > 0
      witness.keys.len() == 1
      witness.codeHashes.len() == 1
      codes.len() == 1
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))

  test "Set storage":
    ledger.setStorage(addr1, slot1, 20.u256)
    ledger.persist()

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    var codes: seq[seq[byte]]
    let witness = Witness.build(ledger, codes)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      codes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))

  test "Get storage":
    ledger.setStorage(addr1, slot1, 20.u256)
    ledger.persist(clearWitness = true)

    discard ledger.getStorage(addr1, slot1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    var codes: seq[seq[byte]]
    let witness = Witness.build(ledger, codes)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      codes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))

  test "Get committed storage":
    ledger.setStorage(addr1, slot1, 20.u256)
    ledger.persist(clearWitness = true)

    discard ledger.getCommittedStorage(addr1, slot1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    var codes: seq[seq[byte]]
    let witness = Witness.build(ledger, codes)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      codes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))

  test "Get code and storage slots":
    ledger.setCode(addr1, code)
    ledger.setStorage(addr1, slot1, 100.u256)
    ledger.setStorage(addr1, slot2, 200.u256)
    ledger.setStorage(addr1, slot3, 300.u256)
    ledger.persist(clearWitness = true)

    discard ledger.getCode(addr1)
    discard ledger.getStorage(addr1, slot1)
    discard ledger.getStorage(addr1, slot2)
    discard ledger.getStorage(addr1, slot3)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 4

    var codes: seq[seq[byte]]
    let witness = Witness.build(ledger, codes)

    check:
      witness.state.len() > 0
      witness.keys.len() == 4
      witness.codeHashes.len() == 1
      codes.len() == 1
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot2)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot3)))

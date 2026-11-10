# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/tables,
  stew/byteutils,
  unittest2,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/common/common,
  ../../execution_chain/stateless/[witness_generation, witness_verification]

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

    let witness = Witness.build(witnessKeys, @[], ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 1
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witness.validateKeys(witnessKeys).isOk()

  test "Get code":
    discard ledger.getCode(addr1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 1

    let witness = Witness.build(witnessKeys, @[], ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 1
      witness.codeHashes.len() == 1
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witness.validateKeys(witnessKeys).isOk()

  test "Set storage":
    ledger.setStorage(addr1, slot1, 20.u256)
    ledger.persist()

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    let witness = Witness.build(witnessKeys, @[], ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))
      witness.validateKeys(witnessKeys).isOk()

  test "Get storage":
    discard ledger.getStorage(addr1, slot1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    let witness = Witness.build(witnessKeys, @[], ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))
      witness.validateKeys(witnessKeys).isOk()

  test "Get committed storage":
    discard ledger.getCommittedStorage(addr1, slot1)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 2

    let witness = Witness.build(witnessKeys, @[], ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 2
      witness.codeHashes.len() == 0
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))
      witness.validateKeys(witnessKeys).isOk()

  test "Get code and storage slots":
    discard ledger.getCode(addr1)
    discard ledger.getStorage(addr1, slot1)
    discard ledger.getStorage(addr1, slot2)
    discard ledger.getStorage(addr1, slot3)

    let witnessKeys = ledger.getWitnessKeys()
    check witnessKeys.len() == 4

    let witness = Witness.build(witnessKeys, @[], ledger)

    check:
      witness.state.len() > 0
      witness.keys.len() == 4
      witness.codeHashes.len() == 1
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.none(UInt256)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot1)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot2)))
      witnessKeys.contains((Address.copyFrom(witness.keys[0]), Opt.some(slot3)))
      witness.validateKeys(witnessKeys).isOk()

  test "Order of keys":
    var witnessKeys: WitnessTable
    witnessKeys[(addr1, Opt.none(UInt256))] = true
    witnessKeys[(addr1, Opt.some(slot1))] = false
    witnessKeys[(addr2, Opt.none(UInt256))] = false
    witnessKeys[(addr1, Opt.some(slot2))] = false
    witnessKeys[(addr1, Opt.some(slot3))] = false
    check witnessKeys.len() == 5

    let witness = Witness.build(witnessKeys, @[], ledger)

    check:
      witness.keys.len() == 5
      witness.keys[0] == addr2.data()
      witness.keys[1] == addr1.data()
      witness.keys[2] == slot1.toBytesBE()
      witness.keys[3] == slot2.toBytesBE()
      witness.keys[4] == slot3.toBytesBE()
      witness.validateKeys(witnessKeys).isOk()

suite "Stateless: Witness Generation - collapses undone later in the block":
  func nibble(path: Hash32, i: int): int =
    let b = path.data[i div 2]
    int(if i mod 2 == 0: b shr 4 else: b and 0x0f)

  template findSlot(cond: untyped): UInt256 =
    ## First slot whose hashed path satisfies `cond` (on the injected `path`)
    var res = 0.u256
    for i in 1 .. 100_000:
      let path {.inject.} = keccak256(i.u256.toBytesBE())
      if cond:
        res = i.u256
        break
    doAssert res != 0.u256
    res

  proc statelessLedger(witness: Witness, preStateRoot: Hash32): LedgerRef =
    ## A ledger loaded from the witness only, as the guest uses
    var nodes: Table[Hash32, seq[byte]]
    for node in witness.state:
      nodes[keccak256(node)] = node
    let frame = newCoreDbRef(DefaultDbMemory).baseTxFrame()
    doAssert frame.putSubtrie(preStateRoot, nodes).isOk()
    LedgerRef.init(frame, false, stateless = true)

  proc writeSlots(ledger: LedgerRef, contract: Address, txs: openArray[(UInt256, UInt256)]) =
    ## Each (slot, value) write is its own transaction
    for (slot, value) in txs:
      ledger.setStorage(contract, slot, value)
      ledger.persist()

  setup:
    let
      memDB = newCoreDbRef DefaultDbMemory
      preState = LedgerRef.init(memDB.baseTxFrame(), false)
      contract = address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6"

  test "Storage collapse onto a branch, restored by a re-insert":
    # Storage trie:
    #
    #          [root branch]
    #          /           \
    #     [leaf a]     [branch B]
    #                   /      \
    #             [leaf s1]  [leaf s2]
    #
    # tx1 deletes a: the root collapses onto B.
    # tx2 re-inserts a: the root branch is back, so B is not needed.
    let
      a = 1.u256
      pa = keccak256(a.toBytesBE())
      s1 = findSlot(nibble(path, 0) != nibble(pa, 0))
      ps1 = keccak256(s1.toBytesBE())
      s2 = findSlot(nibble(path, 0) == nibble(ps1, 0) and nibble(path, 1) != nibble(ps1, 1))
      txs = [(a, 0.u256), (a, 2.u256)]
    preState.writeSlots(contract, [(a, 1.u256), (s1, 1.u256), (s2, 1.u256)])

    # Host: run the block and build the witness
    let host = LedgerRef.init(memDB.baseTxFrame().txFrameBegin(), false, collectWitness = true)
    host.writeSlots(contract, txs)
    let witness =
      Witness.build(host.getWitnessKeys(), host.txFrame.getCollapsedSiblings(), preState)

    # Guest: run the block on the witness only
    let guest = witness.statelessLedger(preState.getStateRoot())
    guest.writeSlots(contract, txs)

    check:
      host.txFrame.getCollapsedSiblings().len == 0
      guest.fatalError.isNone()
      not guest.txFrame.hasUnprovenCollapse()
      guest.getStateRoot() == host.getStateRoot()

  test "Account collapse onto a leaf, restored by a re-create":
    # State trie:
    #
    #        [root branch]
    #        /           \
    #   [leaf x]      [leaf y]
    #
    # tx1 destroys x: the root collapses onto y's leaf.
    # tx2 re-creates x: the root branch is back, so y's leaf is not needed.
    var x, y: Address
    x.data[19] = 1
    for i in 2 .. 255:
      y.data[19] = byte(i)
      if nibble(keccak256(y.data), 0) != nibble(keccak256(x.data), 0):
        break
    preState.setBalance(x, 1.u256)
    preState.setBalance(y, 1.u256)
    preState.persist()

    # Host: run the block and build the witness
    let host = LedgerRef.init(memDB.baseTxFrame().txFrameBegin(), false, collectWitness = true)
    host.selfDestruct(x)
    host.persist()
    host.setBalance(x, 2.u256)
    host.persist()
    let witness =
      Witness.build(host.getWitnessKeys(), host.txFrame.getCollapsedSiblings(), preState)

    # Guest: run the block on the witness only
    let guest = witness.statelessLedger(preState.getStateRoot())
    guest.selfDestruct(x)
    guest.persist()
    guest.setBalance(x, 2.u256)
    guest.persist()

    check:
      host.txFrame.getCollapsedSiblings().len == 0
      guest.fatalError.isNone()
      not guest.txFrame.hasUnprovenCollapse()
      guest.getStateRoot() == host.getStateRoot()

  test "Storage collapse onto a leaf, split higher up by an insert":
    # Storage trie:
    #
    #          [root branch]
    #          /           \
    #     [leaf k]     [extension]
    #                       |
    #                  [branch E]
    #                   /      \
    #              [leaf a]  [leaf s]
    #
    # tx1 deletes a: E collapses onto s's leaf.
    # tx2 inserts d, which leaves the path of a and s inside the extension:
    # the trie splits above E, which stays collapsed, so s's leaf is needed.
    let
      k = 1.u256
      a = findSlot(nibble(path, 0) != nibble(keccak256(k.toBytesBE()), 0))
      pa = keccak256(a.toBytesBE())
      s = findSlot(nibble(path, 0) == nibble(pa, 0) and
        nibble(path, 1) == nibble(pa, 1) and nibble(path, 2) != nibble(pa, 2))
      d = findSlot(nibble(path, 0) == nibble(pa, 0) and nibble(path, 1) != nibble(pa, 1))
      txs = [(a, 0.u256), (d, 2.u256)]
    preState.writeSlots(contract, [(k, 1.u256), (a, 1.u256), (s, 1.u256)])

    # Host: run the block and build the witness
    let host = LedgerRef.init(memDB.baseTxFrame().txFrameBegin(), false, collectWitness = true)
    host.writeSlots(contract, txs)
    let witness =
      Witness.build(host.getWitnessKeys(), host.txFrame.getCollapsedSiblings(), preState)

    # Guest: run the block on the witness only
    let guest = witness.statelessLedger(preState.getStateRoot())
    guest.writeSlots(contract, txs)

    check:
      host.txFrame.getCollapsedSiblings().len == 1 # s's leaf
      guest.fatalError.isNone()
      not guest.txFrame.hasUnprovenCollapse()
      guest.getStateRoot() == host.getStateRoot()

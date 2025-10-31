# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  unittest2,
  stint,
  eth/common/[hashes, addresses, accounts],
  ../execution_chain/db/[ledger, core_db],
   ../execution_chain/common/chain_config

proc getGenesisAlloc(filePath: string): GenesisAlloc =
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  cn.genesis.alloc

proc setupLedger(genAccounts: GenesisAlloc, ledger: LedgerRef): Hash32 =

  for address, genAccount in genAccounts:
    for slotKey, slotValue in genAccount.storage:
      ledger.setStorage(address, slotKey, slotValue)

    ledger.setNonce(address, genAccount.nonce)
    ledger.setCode(address, genAccount.code)
    ledger.setBalance(address, genAccount.balance)

  ledger.persist()

  ledger.getStateRoot()

func toNodesTable(proofNodes: openArray[seq[byte]]): Table[Hash32, seq[byte]] =
  var nodes: Table[Hash32, seq[byte]]
  for n in proofNodes:
    nodes[keccak256(n)] = n
  nodes

suite "Aristo subtries json tests":

  let genesisFiles = [
    "berlin2000.json",
    "chainid1.json",
    "chainid7.json",
    "merge.json",
    "devnet4.json",
    "devnet5.json",
    "prague.json",
    "mekong.json"
  ]

  test "Single account proof subtries and check stateRoot":
    for file in genesisFiles:

      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        txFrame = coreDb.baseTxFrame().txFrameBegin()
        ledger = LedgerRef.init(txFrame)
        stateRoot = setupLedger(accounts, ledger)

      for address, account in accounts:
        let
          subtrieDb = newCoreDbRef(DefaultDbMemory)
          subtrieTxFrame = subtrieDb.baseTxFrame().txFrameBegin()
          proof = ledger.getAccountProof(address)
          nodes = toNodesTable(proof)

        # Check the state root of the subtrie
        check:
          subtrieTxFrame.putSubtrie(stateRoot, nodes).isOk()
          subtrieTxFrame.getStateRoot().get() == stateRoot

        # Get the values from the subtrie
        let
          fullTrieLedger = LedgerRef.init(txFrame.txFrameBegin())
          subtrieLedger = LedgerRef.init(subtrieTxFrame.txFrameBegin())
        check:
          fullTrieLedger.getStateRoot() == stateRoot
          subtrieLedger.getBalance(address) == account.balance

        # Update values in the subtrie and check that the state root matches the full trie
        fullTrieLedger.addBalance(address, 1.u256)
        fullTrieLedger.persist()
        subtrieLedger.addBalance(address, 1.u256)
        subtrieLedger.persist()

        check:
          fullTrieLedger.getStateRoot() != stateRoot
          fullTrieLedger.getStateRoot() == subtrieLedger.getStateRoot()

  test "Single account proof with storage proofs subtries and check stateRoot":
    for file in genesisFiles:

      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        txFrame = coreDb.baseTxFrame().txFrameBegin()
        ledger = LedgerRef.init(txFrame)
        stateRoot = setupLedger(accounts, ledger)

      for address, account in accounts:
        let
          subtrieDb = newCoreDbRef(DefaultDbMemory)
          subtrieTxFrame = subtrieDb.baseTxFrame().txFrameBegin()

        var
          proofNodes = ledger.getAccountProof(address)
          slots: seq[UInt256]
        for k in account.storage.keys():
          slots.add(k)

        let storageProof = ledger.getStorageProof(address, slots)
        for slotProof in storageProof:
          proofNodes &= slotProof
        let nodes = toNodesTable(proofNodes)

        # Check the state root of the subtrie
        check:
          subtrieTxFrame.putSubtrie(stateRoot, nodes).isOk()
          subtrieTxFrame.getStateRoot().get() == stateRoot

        # Get the values from the subtrie
        let
          fullTrieLedger = LedgerRef.init(txFrame.txFrameBegin())
          subtrieLedger = LedgerRef.init(subtrieTxFrame.txFrameBegin())
        check:
          fullTrieLedger.getStateRoot() == stateRoot
          subtrieLedger.getBalance(address) == account.balance
        for k, v in account.storage.pairs():
          check subtrieLedger.getStorage(address, k) == v

        # Update values in the subtrie and check that the state root matches the full trie
        fullTrieLedger.addBalance(address, 1.u256)
        for k, v in account.storage.pairs():
          fullTrieLedger.setStorage(address, k, v + 1.u256)
        fullTrieLedger.persist()

        subtrieLedger.addBalance(address, 1.u256)
        for k, v in account.storage.pairs():
          subtrieLedger.setStorage(address, k, v + 1.u256)
        subtrieLedger.persist()

        check:
          fullTrieLedger.getStateRoot() != stateRoot
          fullTrieLedger.getStateRoot() == subtrieLedger.getStateRoot()

  test "Single account and storage multiproof subtries and check stateRoot":
    for file in genesisFiles:

      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        ledger = LedgerRef.init(coreDb.baseTxFrame())
        stateRoot = setupLedger(accounts, ledger)

      for address, account in accounts:
        let
          coreDb2 = newCoreDbRef(DefaultDbMemory)
          txFrame = coreDb2.baseTxFrame().txFrameBegin()

        var slots: seq[Hash32]
        for k in account.storage.keys():
          slots.add(keccak256(k.toBytesBE()))

        var paths: Table[Hash32, seq[Hash32]]
        paths[keccak256(address.data())] = slots

        var proofNodes: seq[seq[byte]]
        ledger.txFrame.multiProof(paths, proofNodes).expect("ok")
        let nodes = toNodesTable(proofNodes)

        check:
          paths.len() == 1
          proofNodes.len() > 0
          nodes.len() > 0
          txFrame.putSubtrie(stateRoot, nodes).isOk()
          txFrame.getStateRoot().get() == stateRoot

  test "All accounts and storage multiproof subtries and check stateRoot":
    for file in genesisFiles:

      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        ledger = LedgerRef.init(coreDb.baseTxFrame())
        stateRoot = setupLedger(accounts, ledger)

      let
        coreDb2 = newCoreDbRef(DefaultDbMemory)
        txFrame = coreDb2.baseTxFrame().txFrameBegin()

      var paths: Table[Hash32, seq[Hash32]]

      for address, account in accounts:
        var slots: seq[Hash32]
        for k in account.storage.keys():
          slots.add(keccak256(k.toBytesBE()))

        paths[keccak256(address.data())] = slots

      var proofNodes: seq[seq[byte]]
      ledger.txFrame.multiProof(paths, proofNodes).expect("ok")
      let nodes = toNodesTable(proofNodes)

      check:
        paths.len() == accounts.len()
        proofNodes.len() > 0
        nodes.len() > 0
        txFrame.putSubtrie(stateRoot, nodes).isOk()
        txFrame.getStateRoot().get() == stateRoot

  # By using a small value (1 in this case) and storing a large number of keys
  # this test reproduces the scenario where leaf trie nodes get embedded into
  # the parent node because the len of the rlp encoded node is less than 32.
  test "Embedded storage leafs and check stateRoot":
    const iterations = 110_000

    let
      coreDb = newCoreDbRef(DefaultDbMemory)
      txFrame = coreDb.baseTxFrame().txFrameBegin()
      ledger = LedgerRef.init(txFrame)
      address = address"0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"
      slotValue = 1.u256

    ledger.setBalance(address, 10.u256)

    var slotPaths: seq[Hash32]
    for i in 0 ..< iterations:
      let slot = i.u256
      ledger.setStorage(address, slot, slotValue)
      slotPaths.add(keccak256(slot.toBytesBE()))
    ledger.persist()

    let stateRoot = ledger.getStateRoot()

    var paths: Table[Hash32, seq[Hash32]]
    paths[keccak256(address.data())] = slotPaths

    var proofNodes: seq[seq[byte]]
    ledger.txFrame.multiProof(paths, proofNodes).expect("ok")
    let nodes = toNodesTable(proofNodes)

    let
      subtrieDb = newCoreDbRef(DefaultDbMemory)
      subtrieTxFrame = subtrieDb.baseTxFrame().txFrameBegin()

    check:
      paths.len() == 1
      proofNodes.len() > 0
      nodes.len() > 0
      subtrieTxFrame.putSubtrie(stateRoot, nodes).isOk()
      subtrieTxFrame.getStateRoot().get() == stateRoot

    # Get the values from the subtrie
    let
      fullTrieLedger = LedgerRef.init(txFrame.txFrameBegin())
      subtrieLedger = LedgerRef.init(subtrieTxFrame.txFrameBegin())
    check:
      fullTrieLedger.getStateRoot() == stateRoot
      subtrieLedger.getBalance(address) == 10.u256
    for i in 0 ..< iterations:
      check subtrieLedger.getStorage(address, i.u256) == slotValue

    # Update values in the subtrie and check that the state root matches the full trie
    fullTrieLedger.addBalance(address, 1000.u256)
    fullTrieLedger.setStorage(address, 0.u256, 100.u256)
    fullTrieLedger.persist()
    subtrieLedger.addBalance(address, 1000.u256)
    subtrieLedger.setStorage(address, 0.u256, 100.u256)
    subtrieLedger.persist()

    check:
      fullTrieLedger.getStateRoot() != stateRoot
      subtrieLedger.getStateRoot() == fullTrieLedger.getStateRoot()

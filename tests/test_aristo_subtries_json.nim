# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
    "holesky.json",
    "prague.json",
    "mekong.json"
  ]

  test "Single account proof subtries and check stateRoot":
    for file in genesisFiles:

      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        ledger = LedgerRef.init(coreDb.baseTxFrame())
        stateRoot = setupLedger(accounts, ledger)

      for address, genAccount in accounts:
        let
          coreDb2 = newCoreDbRef(DefaultDbMemory)
          txFrame = coreDb2.baseTxFrame().txFrameBegin()
          proof = ledger.getAccountProof(address)
          nodes = toNodesTable(proof)

        check:
          txFrame.putSubTrie(stateRoot, nodes).isOk()
          txFrame.getStateRoot().get() == stateRoot

  test "Single account proof with storage proofs subtries and check stateRoot":
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

        var
          proofNodes = ledger.getAccountProof(address)
          slots: seq[UInt256]
        for k in account.storage.keys():
          slots.add(k)

        let storageProof = ledger.getStorageProof(address, slots)
        for slotProof in storageProof:
          # echo "slotProof.len(): ", slotProof.len()
          proofNodes &= slotProof
        let nodes = toNodesTable(proofNodes)

        check:
          txFrame.putSubTrie(stateRoot, nodes).isOk()
          txFrame.getStateRoot().get() == stateRoot

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
          txFrame.putSubTrie(stateRoot, nodes).isOk()
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
        txFrame.putSubTrie(stateRoot, nodes).isOk()
        txFrame.getStateRoot().get() == stateRoot

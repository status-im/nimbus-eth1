# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  unittest2,
  stint,
  eth/common/[hashes, addresses, accounts, accounts_rlp],
  eth/rlp,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/db/[ledger, core_db],
  ../execution_chain/common/[chain_config_loader, genesis]

proc getGenesisAlloc(filePath: string): GenesisAlloc =
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  cn.genesis.alloc

func toNodesTable(proofNodes: openArray[seq[byte]]): Table[Hash32, seq[byte]] =
  var nodes: Table[Hash32, seq[byte]]
  for n in proofNodes:
    nodes[keccak256(n)] = n
  nodes

func hexPrefix(nibbles: openArray[int], isLeaf: bool): seq[byte] =
  let odd = nibbles.len mod 2
  var res: seq[byte]
  res.add byte((if isLeaf: 0x20 else: 0x00) or (odd shl 4) or
    (if odd == 1: nibbles[0] else: 0))
  for i in countup(odd, nibbles.high, 2):
    res.add byte(nibbles[i] shl 4 or nibbles[i + 1])
  res

func shortNode(nibbles: openArray[int], isLeaf: bool, payload: seq[byte]): seq[byte] =
  var w = initRlpList(2)
  w.append(hexPrefix(nibbles, isLeaf))
  w.append(payload)
  w.finish()

func branchNode(children: openArray[(int, Hash32)]): seq[byte] =
  var slots: array[16, seq[byte]]
  for (i, h) in children:
    slots[i] = @(h.data)
  var w = initRlpList(17)
  for s in slots:
    w.append(s)
  w.append(newSeq[byte]())
  w.finish()

func pathOf(nibbles: openArray[int]): Hash32 =
  ## Pads `nibbles` with zeros to a 64-nibble path.
  var data: array[32, byte]
  for i, n in nibbles:
    data[i div 2] = data[i div 2] or byte(if i mod 2 == 0: n shl 4 else: n)
  Hash32(data)

func zeros(n: int): seq[int] =
  newSeq[int](n)

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
        stateRoot = writeGenesisAlloc(accounts, txFrame)

      for address, account in accounts:
        let
          subtrieDb = newCoreDbRef(DefaultDbMemory)
          subtrieTxFrame = subtrieDb.baseTxFrame().txFrameBegin()
          proof = txFrame.proof(address.computeAccPath())[][0]
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
        stateRoot = writeGenesisAlloc(accounts, txFrame)

      for address, account in accounts:
        let
          subtrieDb = newCoreDbRef(DefaultDbMemory)
          subtrieTxFrame = subtrieDb.baseTxFrame().txFrameBegin()

        var
          proof = txFrame.proof(address.computeAccPath())[]
          proofNodes = proof[0]
          slots: seq[Hash32]
        for k in account.storage.keys():
          slots.add(k.computeSlotKey())

        let storageProof =
          if proof[1]:
            txFrame.slotProofs(address.computeAccPath(), slots)[]
          else:
            newSeq[seq[seq[byte]]](slots.len)
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
        txFrame = coreDb.baseTxFrame()
        stateRoot = writeGenesisAlloc(accounts, txFrame)

      for address, account in accounts:
        let
          coreDb2 = newCoreDbRef(DefaultDbMemory)
          txFrame2 = coreDb2.baseTxFrame().txFrameBegin()

        var slots: seq[Hash32]
        for k in account.storage.keys():
          slots.add(keccak256(k.toBytesBE()))

        var paths: Table[Hash32, seq[Hash32]]
        paths[keccak256(address.data())] = slots

        var proofNodes: seq[seq[byte]]
        txFrame.multiProof(paths, [], proofNodes).expect("ok")
        let nodes = toNodesTable(proofNodes)

        check:
          paths.len() == 1
          proofNodes.len() > 0
          nodes.len() > 0
          txFrame2.putSubtrie(stateRoot, nodes).isOk()
          txFrame2.getStateRoot().get() == stateRoot

  test "All accounts and storage multiproof subtries and check stateRoot":
    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        txFrame = coreDb.baseTxFrame()
        stateRoot = writeGenesisAlloc(accounts, txFrame)

      let
        coreDb2 = newCoreDbRef(DefaultDbMemory)
        txFrame2 = coreDb2.baseTxFrame().txFrameBegin()

      var paths: Table[Hash32, seq[Hash32]]

      for address, account in accounts:
        var slots: seq[Hash32]
        for k in account.storage.keys():
          slots.add(keccak256(k.toBytesBE()))

        paths[keccak256(address.data())] = slots

      var proofNodes: seq[seq[byte]]
      txFrame.multiProof(paths, [], proofNodes).expect("ok")
      let nodes = toNodesTable(proofNodes)

      check:
        paths.len() == accounts.len()
        proofNodes.len() > 0
        nodes.len() > 0
        txFrame2.putSubtrie(stateRoot, nodes).isOk()
        txFrame2.getStateRoot().get() == stateRoot

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
    ledger.txFrame.multiProof(paths, [], proofNodes).expect("ok")
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

  test "Branch collapse onto a node absent from the witness":
    # The witness proves a and e, so S is known only by its hash:
    #
    #              [R: branch]
    #              /0        \5
    #        [ext 0]        [leaf e]
    #           |
    #       [B: branch]
    #        /0      \1
    #   [leaf a]    {S: branch}
    #                /0    \1
    #              s1      s2
    #
    # c (0,0,2) goes next to S in B, b (0,1) diverges above B.
    let
      a = pathOf([0, 0, 0])
      b = pathOf([0, 1])
      c = pathOf([0, 0, 2])
      e = pathOf([5])
      acc = CoreDbAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH)

    type Dbs = object
      full: CoreDbTxRef    # holds the whole trie
      witness: CoreDbTxRef # holds only the witness of a and e

    proc setup(): Dbs =
      let full = newCoreDbRef(DefaultDbMemory).baseTxFrame().txFrameBegin()
      for path in [a, pathOf([0, 0, 1, 0]), pathOf([0, 0, 1, 1]), e]:
        doAssert full.mergeAccount(path, acc).isOk()
      var paths: Table[Hash32, seq[Hash32]]
      paths[a] = @[]
      paths[e] = @[]
      var proofNodes: seq[seq[byte]]
      full.multiProof(paths, [], proofNodes).expect("ok")
      let witness = newCoreDbRef(DefaultDbMemory).baseTxFrame().txFrameBegin()
      doAssert witness.putSubtrie(full.getStateRoot().get(), toNodesTable(proofNodes)).isOk()
      Dbs(full: full, witness: witness)

    # Each change is applied to both databases
    proc delete(dbs: Dbs, path: Hash32): bool =
      dbs.full.deleteAccount(path).isOk() and dbs.witness.deleteAccount(path).isOk()

    proc insert(dbs: Dbs, path: Hash32): bool =
      dbs.full.mergeAccount(path, acc).isOk() and dbs.witness.mergeAccount(path, acc).isOk()

    proc rootsMatch(dbs: Dbs): bool =
      dbs.witness.getStateRoot().get() == dbs.full.getStateRoot().get()

    proc witnessHasUnprovenCollapse(dbs: Dbs): bool =
      LedgerRef.init(dbs.witness).hasUnprovenCollapse()

    block: # Deleting a collapses B onto S, which needs S
      let dbs = setup()
      check:
        dbs.delete(a)
        dbs.rootsMatch()
        dbs.witnessHasUnprovenCollapse()

    block: # Inserting c restores B
      let dbs = setup()
      check:
        dbs.delete(a)
        dbs.insert(c)
        dbs.rootsMatch()
        not dbs.witnessHasUnprovenCollapse()

    block: # Inserting b splits above B, which stays collapsed
      let dbs = setup()
      check:
        dbs.delete(a)
        dbs.insert(b)
        dbs.rootsMatch()
        dbs.witnessHasUnprovenCollapse()

    block: # R collapses onto the collapsed B, then a re-insert restores B
      let dbs = setup()
      check:
        dbs.delete(a)
        dbs.delete(e)
        dbs.witnessHasUnprovenCollapse()
        dbs.insert(a)
        dbs.rootsMatch()
        not dbs.witnessHasUnprovenCollapse()

  test "Branch shared by a branch parent and an extension parent":
    let
      one = rlp.encode(1.u256)
      two = rlp.encode(2.u256)
      leaf0 = shortNode(zeros(58), true, one)
      leaf1 = shortNode(zeros(58), true, two)
      shared = branchNode([(0, keccak256(leaf0)), (1, keccak256(leaf1))])

      # Storage trie 1: ext 0000 -> branch {6: shared, 7: leaf}
      leaf7 = shortNode(zeros(59), true, one)
      branch1 = branchNode([(6, keccak256(shared)), (7, keccak256(leaf7))])
      root1 = shortNode([0, 0, 0, 0], false, @(keccak256(branch1).data))

      # Storage trie 2: branch {0: ext 0006 -> shared, 1: leaf}
      ext2 = shortNode([0, 0, 0, 6], false, @(keccak256(shared).data))
      leaf2 = shortNode(zeros(63), true, one)
      root2 = branchNode([(0, keccak256(ext2)), (1, keccak256(leaf2))])

      # Account 1 sorts first, so its storage trie is converted first.
      acc1 = shortNode(zeros(63), true, rlp.encode(Account(
        balance: 1.u256, storageRoot: keccak256(root1), codeHash: EMPTY_CODE_HASH)))
      acc2 = shortNode(zeros(63), true, rlp.encode(Account(
        balance: 2.u256, storageRoot: keccak256(root2), codeHash: EMPTY_CODE_HASH)))
      stateRoot = branchNode([(1, keccak256(acc1)), (2, keccak256(acc2))])

      nodes = toNodesTable([
        leaf0, leaf1, shared, leaf7, branch1, root1, ext2, leaf2, root2,
        acc1, acc2, stateRoot])
      accPath1 = pathOf([1])
      accPath2 = pathOf([2])
      sharedPath0 = pathOf([0, 0, 0, 0, 6, 0])
      sharedPath1 = pathOf([0, 0, 0, 0, 6, 1])

      db = newCoreDbRef(DefaultDbMemory)
      txFrame = db.baseTxFrame().txFrameBegin()

    check:
      txFrame.putSubtrie(keccak256(stateRoot), nodes).isOk()
      txFrame.getStateRoot().get() == keccak256(stateRoot)
      txFrame.fetchSlot(accPath1, sharedPath0).get(0.u256) == 1.u256
      txFrame.fetchSlot(accPath1, sharedPath1).get(0.u256) == 2.u256
      txFrame.fetchSlot(accPath2, sharedPath0).get(0.u256) == 1.u256
      txFrame.fetchSlot(accPath2, sharedPath1).get(0.u256) == 2.u256

  test "Storage root missing from the witness is not read as empty storage":
    let
      address = address"0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"
      accPath = address.computeAccPath()
      fullLedger = LedgerRef.init(newCoreDbRef(DefaultDbMemory).baseTxFrame().txFrameBegin())

    # Full node: an account with one storage slot
    fullLedger.setBalance(address, 10.u256)
    fullLedger.setStorage(address, 1.u256, 7.u256)
    fullLedger.persist()

    # Witness with the account but without its storage trie
    let
      accountProof = fullLedger.txFrame.proof(accPath).expect("proof")[0]
      witnessTxFrame = newCoreDbRef(DefaultDbMemory).baseTxFrame().txFrameBegin()
    check witnessTxFrame.putSubtrie(fullLedger.getStateRoot(), toNodesTable(accountProof)).isOk()

    # Writing a slot fails. The ledger always reads before it writes, so this
    # can only be checked at this level.
    check witnessTxFrame.mergeSlot(accPath, computeSlotKey(2.u256), 8.u256).isErr()

    # Reading the slot fails, instead of returning 0
    let readLedger =
      LedgerRef.init(witnessTxFrame.txFrameBegin(), storeSlotHash = false, stateless = true)
    discard readLedger.getStorage(address, 1.u256)
    check readLedger.fatalError.isSome()

    # Clearing the storage and then writing a slot needs no storage nodes, and
    # gives the same state root as on the full node
    let clearLedger =
      LedgerRef.init(witnessTxFrame.txFrameBegin(), storeSlotHash = false, stateless = true)
    for ledger in [fullLedger, clearLedger]:
      ledger.clearStorage(address)
      ledger.setStorage(address, 2.u256, 8.u256)
      ledger.persist()
    check:
      clearLedger.fatalError.isNone()
      clearLedger.getStateRoot() == fullLedger.getStateRoot()

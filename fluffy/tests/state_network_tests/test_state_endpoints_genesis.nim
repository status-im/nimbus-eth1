# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  testutils/unittests,
  chronos,
  results,
  eth/trie,
  eth/common/[addresses, hashes],
  ../../../execution_chain/common/chain_config,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/state/
    [state_content, state_network, state_gossip, state_endpoints, state_utils],
  ../../database/content_db,
  ./state_test_helpers

suite "State Endpoints - Genesis JSON Files":
  const STATE_NODE1_PORT = 20702

  const genesisFiles = [
    "berlin2000.json", "calaveras.json", "chainid1.json", "chainid7.json",
    "devnet4.json", "devnet5.json", "holesky.json", "mainshadow1.json", "merge.json",
  ]

  proc setupAccountInDb(
      stateNode: StateNode, accountState: HexaryTrie, address: addresses.Address
  ) =
    let
      proof = accountState.generateAccountProof(address)
      leafNode = proof[^1]
      addressHash = keccak256(address.data)
      path = removeLeafKeyEndNibbles(Nibbles.init(addressHash.data, true), leafNode)
      key = AccountTrieNodeKey.init(path, keccak256(leafNode.asSeq()))
      offer = AccountTrieNodeOffer(proof: proof)

    # store the account leaf node
    let contentKey = key.toContentKey().encode()
    stateNode.portalProtocol.storeContent(
      contentKey, contentKey.toContentId(), offer.toRetrieval().encode()
    )

    # store the account parent nodes / all remaining nodes
    var
      parent = offer.withKey(key).getParent()
      parentContentKey = parent.key.toContentKey().encode()

    stateNode.portalProtocol.storeContent(
      parentContentKey,
      parentContentKey.toContentId(),
      parent.offer.toRetrieval().encode(),
    )

    for i in proof.low ..< proof.high - 1:
      parent = parent.getParent()
      parentContentKey = parent.key.toContentKey().encode()

      stateNode.portalProtocol.storeContent(
        parentContentKey,
        parentContentKey.toContentId(),
        parent.offer.toRetrieval().encode(),
      )

  proc setupCodeInDb(
      stateNode: StateNode, address: addresses.Address, code: seq[byte]
  ) =
    let
      key =
        ContractCodeKey(addressHash: keccak256(address.data), codeHash: keccak256(code))
      value = ContractCodeRetrieval(code: Bytecode.init(code))

    let contentKey = key.toContentKey().encode()
    stateNode.portalProtocol.storeContent(
      contentKey, contentKey.toContentId(), value.encode()
    )

  proc setupSlotInDb(
      stateNode: StateNode,
      accountState: HexaryTrie,
      storageState: HexaryTrie,
      address: addresses.Address,
      slot: UInt256,
  ) =
    let
      addressHash = keccak256(address.data)
      proof = accountState.generateAccountProof(address)
      storageProof = storageState.generateStorageProof(slot)
      leafNode = storageProof[^1]
      path = removeLeafKeyEndNibbles(
        Nibbles.init(keccak256(toBytesBE(slot)).data, true), leafNode
      )
      key = ContractTrieNodeKey(
        addressHash: addressHash, path: path, nodeHash: keccak256(leafNode.asSeq())
      )
      offer = ContractTrieNodeOffer(storageProof: storageProof, accountProof: proof)

    # store the contract storage leaf node
    let contentKey = key.toContentKey().encode()
    stateNode.portalProtocol.storeContent(
      contentKey, contentKey.toContentId(), offer.toRetrieval().encode()
    )

    # store the remaining contract storage nodes
    var
      parent = offer.withKey(key).getParent()
      parentContentKey = parent.key.toContentKey().encode()

    stateNode.portalProtocol.storeContent(
      parentContentKey,
      parentContentKey.toContentId(),
      parent.offer.toRetrieval().encode(),
    )

    for i in storageProof.low ..< storageProof.high - 1:
      parent = parent.getParent()
      parentContentKey = parent.key.toContentKey().encode()

      stateNode.portalProtocol.storeContent(
        parentContentKey,
        parentContentKey.toContentId(),
        parent.offer.toRetrieval().encode(),
      )

  asyncTest "Test getBalance, getTransactionCount, getStorageAt and getCode using JSON files":
    let
      rng = newRng()
      stateNode = newStateNode(rng, STATE_NODE1_PORT)

    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (accountState, storageStates) = accounts.toState()
        blockNumber = 123.uint64 # use a dummy block number

      # mock the block hash because we don't have history network running
      stateNode.mockStateRootLookup(blockNumber, accountState.rootHash())

      for address, account in accounts:
        stateNode.setupAccountInDb(accountState, address)

        # get balance and nonce of existing account
        let
          balanceRes = await stateNode.stateNetwork.getBalance(blockNumber, address)
          nonceRes =
            await stateNode.stateNetwork.getTransactionCount(blockNumber, address)
        check:
          balanceRes.get() == account.balance
          nonceRes.get() == account.nonce

        if account.code.len() > 0:
          stateNode.setupCodeInDb(address, account.code)

          # get code of existing account
          let codeRes = await stateNode.stateNetwork.getCode(blockNumber, address)
          check:
            codeRes.get().asSeq() == account.code

          let storageState = storageStates.getOrDefault(address)
          for slotKey, slotValue in account.storage:
            stateNode.setupSlotInDb(accountState, storageState, address, slotKey)

            # get storage slots of existing account
            let slotRes =
              await stateNode.stateNetwork.getStorageAt(blockNumber, address, slotKey)
            check:
              slotRes.get() == slotValue
        else:
          # account exists but code and slot doesn't exist
          let
            codeRes = await stateNode.stateNetwork.getCode(blockNumber, address)
            slotRes0 =
              await stateNode.stateNetwork.getStorageAt(blockNumber, address, 0.u256)
            slotRes1 =
              await stateNode.stateNetwork.getStorageAt(blockNumber, address, 1.u256)
          check:
            codeRes.get().asSeq().len() == 0
            slotRes0.get() == 0.u256
            slotRes1.get() == 0.u256

      # account doesn't exist
      block:
        let badAddress =
          addresses.Address.fromHex("0xBAD0000000000000000000000000000000000000")

        let
          balanceRes = await stateNode.stateNetwork.getBalance(blockNumber, badAddress)
          nonceRes =
            await stateNode.stateNetwork.getTransactionCount(blockNumber, badAddress)
          codeRes = await stateNode.stateNetwork.getCode(blockNumber, badAddress)
          slotRes =
            await stateNode.stateNetwork.getStorageAt(blockNumber, badAddress, 0.u256)

        check:
          balanceRes.get() == 0.u256
          nonceRes.get() == 0.uint64
          codeRes.get().asSeq().len() == 0
          slotRes.get() == 0.u256

    await stateNode.stop()

  asyncTest "Test getProofs using JSON files":
    let
      rng = newRng()
      stateNode = newStateNode(rng, STATE_NODE1_PORT)

    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (accountState, storageStates) = accounts.toState()
        blockNumber = 123.uint64 # use a dummy block number

      # mock the block hash because we don't have history network running
      stateNode.mockStateRootLookup(blockNumber, accountState.rootHash())

      for address, account in accounts:
        stateNode.setupAccountInDb(accountState, address)

        if account.code.len() > 0:
          stateNode.setupCodeInDb(address, account.code)

          let storageState = storageStates.getOrDefault(address)

          # existing account, no slots
          let
            slotKeys = newSeq[UInt256]()
            proofs = (
              await stateNode.stateNetwork.getProofs(blockNumber, address, slotKeys)
            ).valueOr:
              raiseAssert("Failed to get proofs")
          check:
            proofs.account.balance == account.balance
            proofs.account.nonce == account.nonce
            proofs.account.storageRoot == storageState.rootHash()
            proofs.account.codeHash == keccak256(account.code)
            proofs.accountProof.len() > 0
            proofs.accountProof == accountState.generateAccountProof(address)
            proofs.slots.len() == 0
            proofs.slotProofs.len() == 0

          for slotKey, slotValue in account.storage:
            stateNode.setupSlotInDb(accountState, storageState, address, slotKey)

            # existing account, with slot
            let
              slotKeys = @[slotKey]
              proofs = (
                await stateNode.stateNetwork.getProofs(blockNumber, address, slotKeys)
              ).valueOr:
                raiseAssert("Failed to get proofs")
            check:
              proofs.account.balance == account.balance
              proofs.account.nonce == account.nonce
              proofs.account.storageRoot == storageState.rootHash()
              proofs.account.codeHash == keccak256(account.code)
              proofs.accountProof.len() > 0
              proofs.accountProof == accountState.generateAccountProof(address)
              proofs.slots == @[(slotKey, slotValue)]
              proofs.slotProofs.len() == 1
              proofs.slotProofs[0].len() > 0
              proofs.slotProofs[0] == storageState.generateStorageProof(slotKey)
        else:
          # account exists but code and slot doesn't exist
          let
            slotKeys = @[2.u256]
            proofs = (
              await stateNode.stateNetwork.getProofs(blockNumber, address, slotKeys)
            ).valueOr:
              raiseAssert("Failed to get proofs")
          check:
            proofs.account.balance == account.balance
            proofs.account.nonce == account.nonce
            proofs.account.storageRoot == EMPTY_ROOT_HASH
            proofs.account.codeHash == EMPTY_CODE_HASH
            proofs.accountProof.len() > 0
            proofs.accountProof == accountState.generateAccountProof(address)
            proofs.slots == @[(2.u256, 0.u256)]
            proofs.slotProofs.len() == 1
            proofs.slotProofs[0].len() == 0

      # account doesn't exist
      block:
        let
          badAddress =
            addresses.Address.fromHex("0xBAD0000000000000000000000000000000000000")
          slotKeys = @[0.u256, 1.u256]
          proofs = (
            await stateNode.stateNetwork.getProofs(blockNumber, badAddress, slotKeys)
          ).valueOr:
            raiseAssert("Failed to get proofs")
        check:
          proofs.account == EMPTY_ACCOUNT
          proofs.accountProof.len() > 0
          proofs.accountProof == accountState.generateAccountProof(badAddress)
          proofs.slots == @[(0.u256, 0.u256), (1.u256, 0.u256)]
          proofs.slotProofs.len() == 2
          proofs.slotProofs[0].len() == 0
          proofs.slotProofs[1].len() == 0

    await stateNode.stop()

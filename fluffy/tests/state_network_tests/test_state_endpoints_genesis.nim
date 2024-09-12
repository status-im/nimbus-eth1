# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  testutils/unittests,
  chronos,
  results,
  stew/byteutils,
  eth/[common, trie],
  ../../../nimbus/common/chain_config,
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
      stateNode: StateNode, accountState: HexaryTrie, address: EthAddress
  ) =
    let
      proof = accountState.generateAccountProof(address)
      leafNode = proof[^1]
      addressHash = keccakHash(address)
      path = removeLeafKeyEndNibbles(Nibbles.init(addressHash.data, true), leafNode)
      key = AccountTrieNodeKey.init(path, keccakHash(leafNode.asSeq()))
      offer = AccountTrieNodeOffer(proof: proof)

    # store the account leaf node
    let contentKey = key.toContentKey().encode()
    stateNode.portalProtocol.storeContent(
      contentKey, contentKey.toContentId(), offer.toRetrievalValue().encode()
    )

    # store the account parent nodes / all remaining nodes
    var
      parent = offer.withKey(key).getParent()
      parentContentKey = parent.key.toContentKey().encode()

    stateNode.portalProtocol.storeContent(
      parentContentKey,
      parentContentKey.toContentId(),
      parent.offer.toRetrievalValue().encode(),
    )

    for i in proof.low ..< proof.high - 1:
      parent = parent.getParent()
      parentContentKey = parent.key.toContentKey().encode()

      stateNode.portalProtocol.storeContent(
        parentContentKey,
        parentContentKey.toContentId(),
        parent.offer.toRetrievalValue().encode(),
      )

  proc setupCodeInDb(stateNode: StateNode, address: EthAddress, code: seq[byte]) =
    let
      key =
        ContractCodeKey(addressHash: keccakHash(address), codeHash: keccakHash(code))
      value = ContractCodeRetrieval(code: Bytecode.init(code))

    let contentKey = key.toContentKey().encode()
    stateNode.portalProtocol.storeContent(
      contentKey, contentKey.toContentId(), value.encode()
    )

  proc setupSlotInDb(
      stateNode: StateNode,
      accountState: HexaryTrie,
      storageState: HexaryTrie,
      address: EthAddress,
      slot: UInt256,
  ) =
    let
      addressHash = keccakHash(address)
      proof = accountState.generateAccountProof(address)
      storageProof = storageState.generateStorageProof(slot)
      leafNode = storageProof[^1]
      path = removeLeafKeyEndNibbles(
        Nibbles.init(keccakHash(toBytesBE(slot)).data, true), leafNode
      )
      key = ContractTrieNodeKey(
        addressHash: addressHash, path: path, nodeHash: keccakHash(leafNode.asSeq())
      )
      offer = ContractTrieNodeOffer(storageProof: storageProof, accountProof: proof)

    # store the contract storage leaf node
    let contentKey = key.toContentKey().encode()
    stateNode.portalProtocol.storeContent(
      contentKey, contentKey.toContentId(), offer.toRetrievalValue().encode()
    )

    # store the remaining contract storage nodes
    var
      parent = offer.withKey(key).getParent()
      parentContentKey = parent.key.toContentKey().encode()

    stateNode.portalProtocol.storeContent(
      parentContentKey,
      parentContentKey.toContentId(),
      parent.offer.toRetrievalValue().encode(),
    )

    for i in storageProof.low ..< storageProof.high - 1:
      parent = parent.getParent()
      parentContentKey = parent.key.toContentKey().encode()

      stateNode.portalProtocol.storeContent(
        parentContentKey,
        parentContentKey.toContentId(),
        parent.offer.toRetrievalValue().encode(),
      )

  asyncTest "Test getBalance, getTransactionCount, getStorageAt and getCode using JSON files":
    let
      rng = newRng()
      stateNode = newStateNode(rng, STATE_NODE1_PORT)

    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (accountState, storageStates) = accounts.toState()
        blockHash = keccakHash("blockHash") # use a dummy block hash

      # mock the block hash because we don't have history network running
      stateNode.mockBlockHashToStateRoot(blockHash, accountState.rootHash())

      for address, account in accounts:
        stateNode.setupAccountInDb(accountState, address)

        # get balance and nonce of existing account
        let
          balanceRes = await stateNode.stateNetwork.getBalance(blockHash, address)
          nonceRes =
            await stateNode.stateNetwork.getTransactionCount(blockHash, address)
        check:
          balanceRes.get() == account.balance
          nonceRes.get() == account.nonce

        if account.code.len() > 0:
          stateNode.setupCodeInDb(address, account.code)

          # get code of existing account
          let codeRes = await stateNode.stateNetwork.getCode(blockHash, address)
          check:
            codeRes.get().asSeq() == account.code

          let storageState = storageStates.getOrDefault(address)
          for slotKey, slotValue in account.storage:
            stateNode.setupSlotInDb(accountState, storageState, address, slotKey)

            # get storage slots of existing account
            let slotRes =
              await stateNode.stateNetwork.getStorageAt(blockHash, address, slotKey)
            check:
              slotRes.get() == slotValue
        else:
          # account exists but code and slot doesn't exist
          let
            codeRes = await stateNode.stateNetwork.getCode(blockHash, address)
            slotRes0 =
              await stateNode.stateNetwork.getStorageAt(blockHash, address, 0.u256)
            slotRes1 =
              await stateNode.stateNetwork.getStorageAt(blockHash, address, 1.u256)
          check:
            codeRes.get().asSeq().len() == 0
            slotRes0.get() == 0.u256
            slotRes1.get() == 0.u256

      # account doesn't exist
      block:
        let badAddress =
          EthAddress.fromHex("0xBAD0000000000000000000000000000000000000")

        let
          balanceRes = await stateNode.stateNetwork.getBalance(blockHash, badAddress)
          nonceRes =
            await stateNode.stateNetwork.getTransactionCount(blockHash, badAddress)
          codeRes = await stateNode.stateNetwork.getCode(blockHash, badAddress)
          slotRes =
            await stateNode.stateNetwork.getStorageAt(blockHash, badAddress, 0.u256)

        check:
          balanceRes.get() == 0.u256
          nonceRes.get() == 0.uint64
          codeRes.get().asSeq().len() == 0
          slotRes.get() == 0.u256

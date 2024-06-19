# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  testutils/unittests,
  chronos,
  results,
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

  asyncTest "Test getBalance, getTransactionCount, getStorageAt and getCode using JSON files":
    let
      rng = newRng()
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (accountState, storageStates) = accounts.toState()
        stateRoot = accountState.rootHash()

      for address, account in accounts:
        let
          proof = accountState.generateAccountProof(address)
          leafNode = proof[^1]
          addressHash = keccakHash(address).data
          path = removeLeafKeyEndNibbles(Nibbles.init(addressHash, true), leafNode)
          key = AccountTrieNodeKey.init(path, keccakHash(leafNode.asSeq()))
          offer = AccountTrieNodeOffer(proof: proof)

        # store the account leaf node
        let contentKey = key.toContentKey().encode()
        stateNode1.portalProtocol.storeContent(
          contentKey, contentKey.toContentId(), offer.toRetrievalValue().encode()
        )

        # store the account parent nodes / all remaining nodes
        var
          parent = offer.withKey(key).getParent()
          parentContentKey = parent.key.toContentKey().encode()

        stateNode1.portalProtocol.storeContent(
          parentContentKey,
          parentContentKey.toContentId(),
          parent.offer.toRetrievalValue().encode(),
        )

        for i in proof.low ..< proof.high - 1:
          parent = parent.getParent()
          parentContentKey = parent.key.toContentKey().encode()

          stateNode1.portalProtocol.storeContent(
            parentContentKey,
            parentContentKey.toContentId(),
            parent.offer.toRetrievalValue().encode(),
          )

        # mock the block hash because we don't have history network running
        stateNode1.mockBlockHashToStateRoot(offer.blockHash, stateRoot)

        # verify can lookup account values by walking the trie via the state network endpoints
        let
          balanceRes =
            await stateNode1.stateNetwork.getBalance(offer.blockHash, address)
          nonceRes =
            await stateNode1.stateNetwork.getTransactionCount(offer.blockHash, address)
        check:
          balanceRes.isOk()
          balanceRes.get() == account.balance
          nonceRes.isOk()
          nonceRes.get() == account.nonce

        if account.code.len() > 0:
          block:
            # store the code
            let
              key =
                ContractCodeKey(address: address, codeHash: keccakHash(account.code))
              value = ContractCodeRetrieval(code: Bytecode.init(account.code))

            let contentKey = key.toContentKey().encode()
            stateNode1.portalProtocol.storeContent(
              contentKey, contentKey.toContentId(), value.encode()
            )

            # verify can lookup code by walking the trie via the state network endpoints
            let codeRes =
              await stateNode1.stateNetwork.getCode(offer.blockHash, address)
            check:
              codeRes.isOk()
              codeRes.get().asSeq() == account.code

          # next test the storage for accounts that have code
          let storageState = storageStates[address]
          for slotKey, slotValue in account.storage:
            let
              storageProof = storageState.generateStorageProof(slotKey)
              leafNode = storageProof[^1]
              slotKeyHash = keccakHash(toBytesBE(slotKey)).data
              path = removeLeafKeyEndNibbles(
                Nibbles.init(keccakHash(toBytesBE(slotKey)).data, true), leafNode
              )
              key = ContractTrieNodeKey(
                address: address, path: path, nodeHash: keccakHash(leafNode.asSeq())
              )
              offer =
                ContractTrieNodeOffer(storageProof: storageProof, accountProof: proof)

            # store the contract storage leaf node
            let contentKey = key.toContentKey().encode()
            stateNode1.portalProtocol.storeContent(
              contentKey, contentKey.toContentId(), offer.toRetrievalValue().encode()
            )

            # store the remaining contract storage nodes
            var
              parent = offer.withKey(key).getParent()
              parentContentKey = parent.key.toContentKey().encode()

            stateNode1.portalProtocol.storeContent(
              parentContentKey,
              parentContentKey.toContentId(),
              parent.offer.toRetrievalValue().encode(),
            )

            for i in storageProof.low ..< storageProof.high - 1:
              parent = parent.getParent()
              parentContentKey = parent.key.toContentKey().encode()

              stateNode1.portalProtocol.storeContent(
                parentContentKey,
                parentContentKey.toContentId(),
                parent.offer.toRetrievalValue().encode(),
              )

            # verify can lookup contract values by walking the trie via the state network endpoints
            let storageAtRes = await stateNode1.stateNetwork.getStorageAt(
              offer.blockHash, address, slotKey
            )
            check:
              storageAtRes.isOk()
              storageAtRes.get() == slotValue

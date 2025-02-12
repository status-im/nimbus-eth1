# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  unittest2,
  results,
  eth/[trie, trie/db],
  eth/common/hashes,
  ../../../execution_chain/common/chain_config,
  ../../network/state/[state_content, state_validation, state_gossip, state_utils],
  ./state_test_helpers

suite "State Gossip getParent - Genesis JSON Files":
  let genesisFiles = [
    "berlin2000.json", "calaveras.json", "chainid1.json", "chainid7.json",
    "devnet4.json", "devnet5.json", "holesky.json", "mainshadow1.json", "merge.json",
  ]

  test "Recursive gossip account leaf nodes":
    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (accountState, _) = accounts.toState()

      for address, account in accounts:
        let
          proof = accountState.generateAccountProof(address)
          leafNode = proof[^1]
          addressHash = keccak256(address.data).data
          path = removeLeafKeyEndNibbles(Nibbles.init(addressHash, true), leafNode)
          key = AccountTrieNodeKey.init(path, keccak256(leafNode.asSeq()))
          offer = AccountTrieNodeOffer(proof: proof)

        var db = newMemoryDB()
        db.put(key.nodeHash.data, offer.toRetrieval().node.asSeq())

        # validate each parent offer until getting to the root node
        var parent = offer.withKey(key).getParent()
        check validateOffer(Opt.some(accountState.rootHash()), parent.key, parent.offer)
        .isOk()
        db.put(parent.key.nodeHash.data, parent.offer.toRetrieval().node.asSeq())

        for i in proof.low ..< proof.high - 1:
          parent = parent.getParent()
          check validateOffer(
            Opt.some(accountState.rootHash()), parent.key, parent.offer
          )
          .isOk()
          db.put(parent.key.nodeHash.data, parent.offer.toRetrieval().node.asSeq())

        # after putting all parent nodes into the trie, verify can lookup the leaf
        let
          trie = initHexaryTrie(db, accountState.rootHash())
          expectedAcc = rlpDecodeAccountTrieNode(leafNode).get()
          accBytes = trie.get(addressHash)
        check rlp.decode(accBytes, Account) == expectedAcc

  test "Recursive gossip contract storage leaf nodes":
    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (accountState, storageStates) = accounts.toState()

      for address, account in accounts:
        let
          addressHash = address.data.keccak256()
          accountProof = accountState.generateAccountProof(address)

        if account.code.len() > 0:
          let storageState = storageStates[address]

          for slotKey, slotValue in account.storage:
            let
              storageProof = storageState.generateStorageProof(slotKey)
              leafNode = storageProof[^1]
              slotKeyHash = keccak256(toBytesBE(slotKey)).data
              path = removeLeafKeyEndNibbles(
                Nibbles.init(keccak256(toBytesBE(slotKey)).data, true), leafNode
              )
              key = ContractTrieNodeKey(
                addressHash: addressHash,
                path: path,
                nodeHash: keccak256(leafNode.asSeq()),
              )
              offer = ContractTrieNodeOffer(
                storageProof: storageProof, accountProof: accountProof
              )

            var db = newMemoryDB()
            db.put(key.nodeHash.data, offer.toRetrieval().node.asSeq())

            # validate each parent offer until getting to the root node
            var parent = offer.withKey(key).getParent()
            check validateOffer(
              Opt.some(accountState.rootHash()), parent.key, parent.offer
            )
            .isOk()
            db.put(parent.key.nodeHash.data, parent.offer.toRetrieval().node.asSeq())

            for i in storageProof.low ..< storageProof.high - 1:
              parent = parent.getParent()
              check validateOffer(
                Opt.some(accountState.rootHash()), parent.key, parent.offer
              )
              .isOk()
              db.put(parent.key.nodeHash.data, parent.offer.toRetrieval().node.asSeq())

            # after putting all parent nodes into the trie, verify can lookup the leaf
            let
              trie = initHexaryTrie(db, storageState.rootHash())
              expectedSlotBytes = rlpFromBytes(leafNode.asSeq()).listElem(1).toBytes()
            check trie.get(slotKeyHash) == expectedSlotBytes

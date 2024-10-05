# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  unittest2,
  results,
  eth/[trie, trie/trie_defs],
  eth/common/[accounts, addresses, hashes],
  ../../../nimbus/common/chain_config,
  ../../network/state/[state_content, state_validation, state_utils],
  ./state_test_helpers

template checkValidProofsForExistingLeafs(
    genAccounts: GenesisAlloc,
    accountState: HexaryTrie,
    storageStates: TableRef[Address, HexaryTrie],
) =
  for address, account in genAccounts:
    var acc = Account.init(account.nonce, account.balance)
    acc.codeHash = keccak256(account.code)

    let
      addressHash = address.data.keccak256()
      accountProof = accountState.generateAccountProof(address)
      accountPath =
        removeLeafKeyEndNibbles(Nibbles.init(addressHash.data, true), accountProof[^1])
      accountTrieNodeKey = AccountTrieNodeKey(
        path: accountPath, nodeHash: keccak256(accountProof[^1].asSeq())
      )
      accountTrieOffer = AccountTrieNodeOffer(proof: accountProof)
      proofResult = validateOffer(
        Opt.some(accountState.rootHash()), accountTrieNodeKey, accountTrieOffer
      )
    check proofResult.isOk()

    let
      contractCodeKey =
        ContractCodeKey(addressHash: addressHash, codeHash: acc.codeHash)
      contractCode =
        ContractCodeOffer(code: Bytecode.init(account.code), accountProof: accountProof)
      codeResult =
        validateOffer(Opt.some(accountState.rootHash()), contractCodeKey, contractCode)
    check codeResult.isOk()

    if account.code.len() > 0:
      let storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      for slotKey, slotValue in account.storage:
        let
          storageProof = storageState.generateStorageProof(slotKey)
          slotPath = removeLeafKeyEndNibbles(
            Nibbles.init(keccak256(toBytesBE(slotKey)).data, true), storageProof[^1]
          )
          contractTrieNodeKey = ContractTrieNodeKey(
            addressHash: addressHash,
            path: slotPath,
            nodeHash: keccak256(storageProof[^1].asSeq()),
          )
          contractTrieOffer = ContractTrieNodeOffer(
            storageProof: storageProof, accountProof: accountProof
          )
          proofResult = validateOffer(
            Opt.some(accountState.rootHash()), contractTrieNodeKey, contractTrieOffer
          )
        check proofResult.isOk()

template checkInvalidProofsWithBadValue(
    genAccounts: GenesisAlloc,
    accountState: HexaryTrie,
    storageStates: TableRef[Address, HexaryTrie],
) =
  for address, account in genAccounts:
    var acc = Account.init(account.nonce, account.balance)
    acc.codeHash = keccak256(account.code)

    var
      addressHash = address.data.keccak256()
      accountProof = accountState.generateAccountProof(address)
      accountPath =
        removeLeafKeyEndNibbles(Nibbles.init(addressHash.data, true), accountProof[^1])
      accountTrieNodeKey = AccountTrieNodeKey(
        path: accountPath, nodeHash: keccak256(accountProof[^1].asSeq())
      )
    accountProof[^1][^1] += 1 # bad account leaf value
    let
      accountTrieOffer = AccountTrieNodeOffer(proof: accountProof)
      proofResult = validateOffer(
        Opt.some(accountState.rootHash()), accountTrieNodeKey, accountTrieOffer
      )
    check proofResult.isErr()

    let
      contractCodeKey =
        ContractCodeKey(addressHash: addressHash, codeHash: acc.codeHash)
      contractCode = ContractCodeOffer(
        code: Bytecode.init(@[1u8, 2, 3]), # bad code value
        accountProof: accountProof,
      )
      codeResult =
        validateOffer(Opt.some(accountState.rootHash()), contractCodeKey, contractCode)
    check codeResult.isErr()

    if account.code.len() > 0:
      let storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      for slotKey, slotValue in account.storage:
        var
          storageProof = storageState.generateStorageProof(slotKey)
          slotPath = removeLeafKeyEndNibbles(
            Nibbles.init(keccak256(toBytesBE(slotKey)).data, true), storageProof[^1]
          )
          contractTrieNodeKey = ContractTrieNodeKey(
            addressHash: addressHash,
            path: slotPath,
            nodeHash: keccak256(storageProof[^1].asSeq()),
          )
        storageProof[^1][^1] += 1 # bad storage leaf value
        let
          contractTrieOffer = ContractTrieNodeOffer(
            storageProof: storageProof, accountProof: accountProof
          )
          proofResult = validateOffer(
            Opt.some(accountState.rootHash()), contractTrieNodeKey, contractTrieOffer
          )
        check proofResult.isErr()

suite "State Validation - Genesis JSON Files":
  let genesisFiles = [
    "berlin2000.json", "calaveras.json", "chainid1.json", "chainid7.json",
    "devnet4.json", "devnet5.json", "holesky.json", "mainshadow1.json", "merge.json",
  ]

  test "Valid proofs for existing leafs":
    for file in genesisFiles:
      let accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
      let state = accounts.toState()
      checkValidProofsForExistingLeafs(accounts, state[0], state[1])

  test "Invalid proofs with bad value":
    for file in genesisFiles:
      let accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
      var state = accounts.toState()
      checkInvalidProofsWithBadValue(accounts, state[0], state[1])

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
  stew/results,
  eth/[common, rlp, trie, trie/trie_defs],
  ../../../nimbus/common/chain_config,
  ../../network/state/state_content,
  ../../network/state/state_validation,
  ./test_helpers

proc checkValidProofsForExistingLeafs(
    genAccounts: GenesisAlloc,
    accountState: HexaryTrie,
    storageStates: Table[EthAddress, HexaryTrie],
) {.raises: [KeyError, RlpError].} =
  for address, account in genAccounts:
    var acc = newAccount(account.nonce, account.balance)
    acc.codeHash = keccakHash(account.code)

    let
      accountProof = accountState.generateAccountProof(address)
      accountTrieNodeKey = AccountTrieNodeKey(
        path: Nibbles.init(keccakHash(address).data),
        nodeHash: keccakHash(accountProof[^1].asSeq()),
      )
      accountTrieOffer = AccountTrieNodeOffer(proof: accountProof)
      proofResult = validateOfferedAccountTrieNode(
        accountState.rootHash(), accountTrieNodeKey, accountTrieOffer
      )
    check proofResult.isOk()

    let
      contractCodeKey = ContractCodeKey(address: address, codeHash: acc.codeHash)
      contractCode =
        ContractCodeOffer(code: Bytecode.init(account.code), accountProof: accountProof)
      codeResult = validateOfferedContractCode(
        accountState.rootHash(), contractCodeKey, contractCode
      )
    check codeResult.isOk()

    if account.code.len() > 0:
      let storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      for slotKey, slotValue in account.storage:
        let
          storageProof = storageState.generateStorageProof(slotKey)
          contractTrieNodeKey = ContractTrieNodeKey(
            address: address,
            path: Nibbles.init(keccakHash(toBytesBE(slotKey)).data),
            nodeHash: keccakHash(storageProof[^1].asSeq()),
          )
          contractTrieOffer = ContractTrieNodeOffer(
            storageProof: storageProof, accountProof: accountProof
          )
          proofResult = validateOfferedContractTrieNode(
            accountState.rootHash(), contractTrieNodeKey, contractTrieOffer
          )
        check proofResult.isOk()

proc checkInvalidProofsWithBadValue(
    genAccounts: GenesisAlloc,
    accountState: HexaryTrie,
    storageStates: Table[EthAddress, HexaryTrie],
) {.raises: [KeyError, RlpError].} =
  for address, account in genAccounts:
    var acc = newAccount(account.nonce, account.balance)
    acc.codeHash = keccakHash(account.code)

    var
      accountProof = accountState.generateAccountProof(address)
      accountTrieNodeKey = AccountTrieNodeKey(
        path: Nibbles.init(keccakHash(address).data),
        nodeHash: keccakHash(accountProof[^1].asSeq()),
      )
    accountProof[^1][^1] += 1 # bad account leaf value
    let
      accountTrieOffer = AccountTrieNodeOffer(proof: accountProof)
      proofResult = validateOfferedAccountTrieNode(
        accountState.rootHash(), accountTrieNodeKey, accountTrieOffer
      )
    check proofResult.isErr()

    let
      contractCodeKey = ContractCodeKey(address: address, codeHash: acc.codeHash)
      contractCode = ContractCodeOffer(
        code: Bytecode.init(@[1u8, 2, 3]), # bad code value
        accountProof: accountProof,
      )
      codeResult = validateOfferedContractCode(
        accountState.rootHash(), contractCodeKey, contractCode
      )
    check codeResult.isErr()

    if account.code.len() > 0:
      let storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      for slotKey, slotValue in account.storage:
        var
          storageProof = storageState.generateStorageProof(slotKey)
          contractTrieNodeKey = ContractTrieNodeKey(
            address: address,
            path: Nibbles.init(keccakHash(toBytesBE(slotKey)).data),
            nodeHash: keccakHash(storageProof[^1].asSeq()),
          )
        storageProof[^1][^1] += 1 # bad storage leaf value
        let
          contractTrieOffer = ContractTrieNodeOffer(
            storageProof: storageProof, accountProof: accountProof
          )
          proofResult = validateOfferedContractTrieNode(
            accountState.rootHash(), contractTrieNodeKey, contractTrieOffer
          )
        check proofResult.isErr()

suite "State Proof Verification Tests":
  let genesisFiles = ["berlin2000.json", "chainid1.json", "chainid7.json", "merge.json"]

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

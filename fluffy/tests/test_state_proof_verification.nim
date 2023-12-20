# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  unittest2,
  stew/results,
  eth/trie, 
  ../../nimbus/db/core_db,
  ../network/state/experimental/[state_proof_generation, state_proof_verification],
  ./test_helpers


suite "State Proof Verification Tests":

  let genesisFiles = ["chainid7.json"]

  test "Valid proofs for existing leafs":

    let genesisAccounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / "chainid7.json")
    let state = genesisAccounts.toState()
    let accountState = state[0]
    let storageStates = state[1]

    for address, account in genesisAccounts:
      var acc = newAccount(account.nonce, account.balance)
      acc.codeHash = keccakHash(account.code)
      let codeResult = verifyContractBytecode(keccakHash(account.code), account.code)
      echo codeResult
      check codeResult.isOk()
      
      if account.code.len() > 0:
        let storageState = storageStates[address]
        acc.storageRoot = storageState.rootHash()

        for slotKey, slotValue in account.storage :
          let storageProof = storageState.generateStorageProof(slotKey)
          let proofResult = verifyContractStorageSlot(acc.storageRoot, slotKey, slotValue, storageProof)
          echo proofResult
          check proofResult.isOk()

      let accountProof = accountState.generateAccountProof(address)
      let proofResult = verifyAccount(accountState.rootHash(), address, acc, accountProof)
      echo proofResult
      check proofResult.isOk()

  # test "Valid proofs for missing leafs":

  #   let genesisAccounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / "chainid7.json")
  #   let state = genesisAccounts.toState()
  #   let accountState = state[0]
  #   let storageStates = state[1]

  #   for address, account in genesisAccounts:
  #     var acc = newAccount(account.nonce, account.balance)
  #     acc.codeHash = keccakHash(account.code)
  #     check verifyContractBytecode(keccakHash(account.code), account.code) == Ok
      
  #     if account.code.len() > 0:
  #       let storageState = storageStates[address]
  #       acc.storageRoot = storageState.rootHash()

  #       for slotKey, slotValue in account.storage :
  #         let storageProof = storageState.generateStorageProof(slotKey)
  #         let proofResult = verifyContractStorageSlot(acc.storageRoot, slotKey, slotValue, storageProof)
  #         echo proofResult
  #         check proofResult.isOk()

        

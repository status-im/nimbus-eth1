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
  ../../nimbus/common/[chain_config],
  ../network/state/experimental/[state_proof_generation, state_proof_verification],
  ./test_helpers

proc checkValidProofsForExistingLeafs(
    genAccounts: GenesisAlloc, 
    accountState: AccountState, 
    storageStates: Table[EthAddress, StorageState]) {.raises: [KeyError, RlpError].} = 

  for address, account in genAccounts:
    var acc = newAccount(account.nonce, account.balance)
    acc.codeHash = keccakHash(account.code)
    let codeResult = verifyContractBytecode(acc.codeHash, account.code)
    #echo codeResult
    check codeResult.isOk()
    
    if account.code.len() > 0:
      let storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      for slotKey, slotValue in account.storage :
        let storageProof = storageState.generateStorageProof(slotKey)
        let proofResult = verifyContractStorageSlot(acc.storageRoot, slotKey, slotValue, storageProof)
        #echo proofResult
        check proofResult.isOk()

    let accountProof = accountState.generateAccountProof(address)
    let proofResult = verifyAccount(accountState.rootHash(), address, acc, accountProof)
    #echo proofResult
    check proofResult.isOk()

proc checkValidProofsForMissingLeafs(
    genAccounts: GenesisAlloc, 
    accountState: var AccountState, 
    storageStates: Table[EthAddress, StorageState]) {.raises: [KeyError, RlpError].} = 
  var remainingAccounts = genAccounts.len()

  for address, account in genAccounts:
    if (remainingAccounts == 1):
      break # can't generate proofs from an empty state

    var acc = newAccount(account.nonce, account.balance)
    acc.codeHash = keccakHash(account.code)

    if account.code.len() > 0:
      var storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      var remainingSlots = account.storage.len()
      for slotKey, slotValue in account.storage:
        if (remainingSlots == 1):
          break # can't generate proofs from an empty state

        storageState.del(keccakHash(toBytesBE(slotKey)).data) # delete the slot from the state
        dec remainingSlots

        let storageProof = storageState.generateStorageProof(slotKey)
        let proofResult = verifyContractStorageSlot(acc.storageRoot, slotKey, slotValue, storageProof)
        #echo proofResult
        check proofResult.isOk()

    accountState.del(keccakHash(address).data) # delete the account from the state
    dec remainingAccounts

    let accountProof = accountState.generateAccountProof(address)
    let proofResult = verifyAccount(accountState.rootHash(), address, acc, accountProof)
    #echo proofResult
    check proofResult.isOk()

proc checkInvalidProofsWithBadStateRoot(
    genAccounts: GenesisAlloc, 
    accountState: AccountState, 
    storageStates: Table[EthAddress, StorageState]) {.raises: [KeyError, RlpError].} = 
  let badHash = toDigest("2cb1b80b285d09e0570fdbbb808e1d14e4ac53e36dcd95dbc268deec2915b3e7")

  for address, account in genAccounts:
    var acc = newAccount(account.nonce, account.balance)
    acc.codeHash = keccakHash(account.code)
    let codeResult = verifyContractBytecode(badHash, account.code)
    check codeResult.isErr()

    if account.code.len() > 0:
      var storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      var remainingSlots = account.storage.len()
      for slotKey, slotValue in account.storage:

        let storageProof = storageState.generateStorageProof(slotKey)
        let proofResult = verifyContractStorageSlot(badHash, slotKey, slotValue, storageProof)
        #echo proofResult
        check: 
          proofResult.isErr()
          proofResult.error() == "missing expected node"

    let accountProof = accountState.generateAccountProof(address)
    let proofResult = verifyAccount(badHash, address, acc, accountProof)
    check: 
      proofResult.isErr()
      proofResult.error() == "missing expected node" 

proc checkInvalidProofsWithBadValue(
    genAccounts: GenesisAlloc, 
    accountState: AccountState, 
    storageStates: Table[EthAddress, StorageState]) {.raises: [KeyError, RlpError].} = 

  for address, account in genAccounts:
    var acc = newAccount(account.nonce, account.balance)
    acc.codeHash = keccakHash(account.code)

    let codeResult = verifyContractBytecode(acc.codeHash, @[1u8, 2, 3]) # bad code value
    check codeResult.isErr()

    if account.code.len() > 0:
      var storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      var remainingSlots = account.storage.len()
      for slotKey, slotValue in account.storage:
        let storageProof = storageState.generateStorageProof(slotKey)
        let badSlotValue = slotValue + 1 # bad slot value

        let proofResult = verifyContractStorageSlot(acc.storageRoot, slotKey, badSlotValue, storageProof)
        #echo proofResult
        check: 
          proofResult.isErr()
          proofResult.error() == "proof does not contain expected value"

    let accountProof = accountState.generateAccountProof(address)
    inc acc.balance # bad account balance
    let proofResult = verifyAccount(accountState.rootHash(), address, acc, accountProof)
    check: 
      proofResult.isErr()
      proofResult.error() == "proof does not contain expected value" 


suite "State Proof Verification Tests":

  let genesisFiles = ["berlin2000.json", "chainid1.json", "chainid7.json", "merge.json"]

  test "Valid proofs for existing leafs":
    for file in genesisFiles:
      let accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
      let state = accounts.toState()
      checkValidProofsForExistingLeafs(accounts, state[0], state[1])

  test "Valid proofs for missing leafs":
    for file in genesisFiles:
      let accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
      var state = accounts.toState()
      checkValidProofsForMissingLeafs(accounts, state[0], state[1])

  test "Invalid proofs with bad state root":
    for file in genesisFiles:
      let accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
      var state = accounts.toState()
      checkInvalidProofsWithBadStateRoot(accounts, state[0], state[1])
 
  test "Invalid proofs with bad value":
    for file in genesisFiles:
      let accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
      var state = accounts.toState()
      checkInvalidProofsWithBadValue(accounts, state[0], state[1])


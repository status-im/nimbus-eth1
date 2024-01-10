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
  ../../nimbus/db/[ledger, core_db],
  ../../nimbus/common/chain_config,
  ../../stateless/[witness_from_tree, multi_keys, witness_types],
  ../network/state/experimental/[state_proof_types, state_proof_generation, state_proof_verification],
  ./test_helpers

proc checkValidProofsForExistingLeafs(
    genAccounts: GenesisAlloc,
    accountState: AccountState,
    storageStates: Table[EthAddress, StorageState]) {.raises: [KeyError, RlpError].} =

  for address, account in genAccounts:
    var acc = newAccount(account.nonce, account.balance)
    acc.codeHash = keccakHash(account.code)
    let codeResult = verifyContractBytecode(acc.codeHash, account.code)
    check codeResult.isOk()

    if account.code.len() > 0:
      let storageState = storageStates[address]
      acc.storageRoot = storageState.rootHash()

      for slotKey, slotValue in account.storage :
        let storageProof = storageState.generateStorageProof(slotKey)
        let proofResult = verifyContractStorageSlot(acc.storageRoot, slotKey, slotValue, storageProof)
        check proofResult.isOk()

    let accountProof = accountState.generateAccountProof(address)
    let proofResult = verifyAccount(accountState.rootHash(), address, acc, accountProof)
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

        storageState.HexaryTrie.del(keccakHash(toBytesBE(slotKey)).data) # delete the slot from the state
        dec remainingSlots

        let storageProof = storageState.generateStorageProof(slotKey)
        let proofResult = verifyContractStorageSlot(acc.storageRoot, slotKey, slotValue, storageProof)
        check proofResult.isErr()

    accountState.HexaryTrie.del(keccakHash(address).data) # delete the account from the state
    dec remainingAccounts

    let accountProof = accountState.generateAccountProof(address)
    let proofResult = verifyAccount(accountState.rootHash(), address, acc, accountProof)
    check proofResult.isErr()

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
        check:
          proofResult.isErr()
          proofResult.error() == "proof does not contain expected value"

    let accountProof = accountState.generateAccountProof(address)
    inc acc.balance # bad account balance
    let proofResult = verifyAccount(accountState.rootHash(), address, acc, accountProof)
    check:
      proofResult.isErr()
      proofResult.error() == "proof does not contain expected value"

proc setupStateDB(
  genAccounts: GenesisAlloc,
  stateDB: LedgerRef): (Hash256, MultikeysRef) =

  var keys = newSeqOfCap[AccountKey](genAccounts.len)

  for address, genAccount in genAccounts:
    var storageKeys = newSeqOfCap[StorageSlot](genAccount.storage.len)

    for slotKey, slotValue in genAccount.storage:
      storageKeys.add(slotKey.toBytesBE)
      stateDB.setStorage(address, slotKey, slotValue)

    stateDB.setNonce(address, genAccount.nonce)
    stateDB.setCode(address, genAccount.code)
    stateDB.setBalance(address, genAccount.balance)

    let sKeys = if storageKeys.len != 0: newMultiKeys(storageKeys) else: MultikeysRef(nil)
    let codeTouched = genAccount.code.len > 0
    keys.add(AccountKey(address: address, codeTouched: codeTouched, storageKeys: sKeys))

  stateDB.persist()
  (stateDB.rootHash, newMultiKeys(keys))

proc buildWitness(
  genAccounts: GenesisAlloc): (KeccakHash, BlockWitness) {.raises: [CatchableError].} =

  let
    coreDb = newCoreDbRef(LegacyDbMemory)
    accountsCache = AccountsCache.init(coreDb, emptyRlpHash, true)
    (rootHash, multiKeys) = setupStateDB(genAccounts, accountsCache)

  var wb = initWitnessBuilder(coreDb, rootHash, {wfEIP170})
  (rootHash, wb.buildWitness(multiKeys))

proc checkWitnessDataMatchesAccounts(
  genAccounts: GenesisAlloc,
  witnessData: TableRef[EthAddress, AccountData]) {.raises: [CatchableError].} =

  for address, genAccount in genAccounts:
    let accountData = witnessData[address]
    check genAccount.code == accountData.code
    check genAccount.storage == accountData.storage
    check genAccount.balance == accountData.account.balance
    check genAccount.nonce == accountData.account.nonce

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

  test "Block witness verification with valid state root":
    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (stateRoot, witness) = buildWitness(accounts)
        verifyResult = verifyWitness(stateRoot, witness)

      check verifyResult.isOk()
      checkWitnessDataMatchesAccounts(accounts, verifyResult.get())

  test "Block witness verification with invalid state root":
    let badStateRoot = toDigest("2cb1b80b285d09e0570fdbbb808e1d14e4ac53e36dcd95dbc268deec2915b3e7")

    for file in genesisFiles:
      let
        accounts = getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / file)
        (stateRoot, witness) = buildWitness(accounts)
        verifyResult = verifyWitness(badStateRoot, witness)

      check verifyResult.isErr()
      check verifyResult.error() == "witness stateRoot doesn't match trustedStateRoot"
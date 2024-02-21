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
  eth/[common, trie/trie_defs],
  ../nimbus/db/[ledger, core_db],
  ../nimbus/common/chain_config,
  ./[witness_from_tree, multi_keys, witness_types, witness_verification]

proc getGenesisAlloc(filePath: string): GenesisAlloc =
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  cn.genesis.alloc

proc setupStateDB(
  genAccounts: GenesisAlloc,
  stateDB: LedgerRef): (Hash256, MultiKeysRef) =

  var keys = newSeqOfCap[AccountKey](genAccounts.len)

  for address, genAccount in genAccounts:
    var storageKeys = newSeqOfCap[StorageSlot](genAccount.storage.len)

    for slotKey, slotValue in genAccount.storage:
      storageKeys.add(slotKey.toBytesBE)
      stateDB.setStorage(address, slotKey, slotValue)

    stateDB.setNonce(address, genAccount.nonce)
    stateDB.setCode(address, genAccount.code)
    stateDB.setBalance(address, genAccount.balance)

    let sKeys = if storageKeys.len != 0: newMultiKeys(storageKeys) else: MultiKeysRef(nil)
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

  var wb = initWitnessBuilder(coreDb, rootHash, {wfNoFlag})
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

proc witnessVerificationMain*() =
  suite "Witness verification json tests":

    let genesisFiles = ["berlin2000.json", "chainid1.json", "chainid7.json", "merge.json", "devnet4.json", "devnet5.json", "holesky.json"]

    test "Block witness verification with valid state root":
      for file in genesisFiles:

        let
          accounts = getGenesisAlloc("tests" / "customgenesis" / file)
          (stateRoot, witness) = buildWitness(accounts)
          verifyResult = verifyWitness(stateRoot, witness, {wfNoFlag})

        check verifyResult.isOk()
        checkWitnessDataMatchesAccounts(accounts, verifyResult.get())

    test "Block witness verification with invalid state root":
      let badStateRoot = toDigest("2cb1b80b285d09e0570fdbbb808e1d14e4ac53e36dcd95dbc268deec2915b3e7")

      for file in genesisFiles:
        let
          accounts = getGenesisAlloc("tests" / "customgenesis" / file)
          (_, witness) = buildWitness(accounts)
          verifyResult = verifyWitness(badStateRoot, witness, {wfNoFlag})

        check verifyResult.isErr()
        check verifyResult.error() == "witness stateRoot doesn't match trustedStateRoot"

when isMainModule:
  witnessVerificationMain()


# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  unittest2,
  stew/byteutils,
  web3/eth_api,
  nimcrypto/[keccak, hash],
  eth/common/[keys, eth_types_rlp],
  eth/[rlp, trie/hexary_proof_verification],
  ../execution_chain/db/[ledger, core_db],
  ../execution_chain/common/chain_config,
  ../execution_chain/rpc/server_api

type
  Hash32 = eth_types.Hash32
  Address = primitives.Address

template toHash32(hash: untyped): Hash32 =
  fromHex(Hash32, hash.toHex())

proc verifyAccountProof(trustedStateRoot: Hash32, res: ProofResponse): MptProofVerificationResult =
  let
    key = keccak256(res.address.data)
    value = rlp.encode(Account(
        nonce: res.nonce.uint64,
        balance: res.balance,
        storageRoot: res.storageHash.toHash32(),
        codeHash: res.codeHash.toHash32()))

  verifyMptProof(
    seq[seq[byte]](res.accountProof),
    trustedStateRoot,
    key.data,
    value)

proc verifySlotProof(trustedStorageRoot: Hash32, slot: StorageProof): MptProofVerificationResult =
  let
    key = keccak256(toBytesBE(slot.key))
    value = rlp.encode(slot.value)

  verifyMptProof(
    seq[seq[byte]](slot.proof),
    trustedStorageRoot,
    key.data,
    value)

proc getGenesisAlloc(filePath: string): GenesisAlloc =
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  cn.genesis.alloc

proc setupLedger(genAccounts: GenesisAlloc, ledger: LedgerRef): Hash32 =

  for address, genAccount in genAccounts:
    for slotKey, slotValue in genAccount.storage:
      ledger.setStorage(address, slotKey, slotValue)

    ledger.setNonce(address, genAccount.nonce)
    ledger.setCode(address, genAccount.code)
    ledger.setBalance(address, genAccount.balance)

  ledger.persist()

  ledger.getStateRoot()

proc checkProofsForExistingLeafs(
    genAccounts: GenesisAlloc,
    accDB: LedgerRef,
    stateRoot: Hash32) =

  for address, account in genAccounts:
    var slots = newSeq[UInt256]()
    for k in account.storage.keys():
      slots.add(k)

    let
      proofResponse = getProof(accDB, address, slots)
      slotProofs = proofResponse.storageProof

    check:
      proofResponse.balance == account.balance
      proofResponse.codeHash.toHash32() == accDB.getCodeHash(address)
      proofResponse.storageHash.toHash32() == accDB.getStorageRoot(address)
      verifyAccountProof(stateRoot, proofResponse).isValid()
      slotProofs.len() == account.storage.len()

    for i, slotProof in slotProofs:
      check:
        slotProof.key == slots[i]
        slotProof.value == account.storage[slotProof.key]
        verifySlotProof(proofResponse.storageHash.toHash32(), slotProof).isValid()

proc checkProofsForMissingLeafs(
    genAccounts: GenesisAlloc,
    accDB: LedgerRef,
    stateRoot: Hash32) =

  let
    missingAddress = Address.fromHex("0x999999cf1046e68e36E1aA2E0E07105eDDD1f08E")
    proofResponse = getProof(accDB, missingAddress, @[])
  check verifyAccountProof(stateRoot, proofResponse).isMissing()

  for address, account in genAccounts:
    let
      missingSlot = u256("987654321123456676466544")
      proofResponse2 = getProof(accDB, address, @[missingSlot])
      slotProofs = proofResponse2.storageProof

    check slotProofs.len() == 1
    if account.storage.len() > 0:
      check verifySlotProof(proofResponse2.storageHash.toHash32(), slotProofs[0]).isMissing()


suite "Get proof json tests":

  let genesisFiles = ["berlin2000.json", "chainid1.json", "chainid7.json", "merge.json", "devnet4.json", "devnet5.json", "holesky.json"]

  test "Get proofs for existing leafs":
    for file in genesisFiles:

      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        ledger = LedgerRef.init(coreDb.baseTxFrame())
        stateRootHash = setupLedger(accounts, ledger)
        accountDb = LedgerRef.init(coreDb.baseTxFrame())

      checkProofsForExistingLeafs(accounts, accountDb, stateRootHash)

  test "Get proofs for missing leafs":
    for file in genesisFiles:

      let
        accounts = getGenesisAlloc("tests" / "customgenesis" / file)
        coreDb = newCoreDbRef(DefaultDbMemory)
        ledger = LedgerRef.init(coreDb.baseTxFrame())
        stateRootHash = setupLedger(accounts, ledger)
        accountDb = LedgerRef.init(coreDb.baseTxFrame())

      checkProofsForMissingLeafs(accounts, accountDb, stateRootHash)

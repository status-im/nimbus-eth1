# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, tables],
  stint,
  eth/[common, rlp, trie/hexary_proof_verification],
  stew/results,
  ./state_proof_types,
  ../../../../stateless/[tree_from_witness, witness_types],
  ../../../../nimbus/db/[core_db, state_db, state_db/base]

export results

proc verifyAccount*(
    trustedStateRoot: KeccakHash,
    address: EthAddress,
    account: Account,
    proof: AccountProof): Result[void, string] =
  if proof.len() == 0:
    return err("proof is empty")

  let key = toSeq(keccakHash(address).data)
  let value = rlp.encode(account)

  let proofResult = verifyMptProof(proof.MptProof, trustedStateRoot, key, value)

  case proofResult.kind
  of ValidProof:
    ok()
  of MissingKey:
    err("missing key")
  of InvalidProof:
    err(proofResult.errorMsg)

proc verifyContractStorageSlot*(
    trustedStorageRoot: KeccakHash,
    slotKey: UInt256,
    slotValue: UInt256,
    proof: StorageProof): Result[void, string] =
  if proof.len() == 0:
    return err("proof is empty")

  let key = toSeq(keccakHash(toBytesBE(slotKey)).data)
  let value = rlp.encode(slotValue)

  let proofResult = verifyMptProof(proof.MptProof, trustedStorageRoot, key, value)

  case proofResult.kind
  of ValidProof:
    ok()
  of MissingKey:
    err("missing key")
  of InvalidProof:
    err(proofResult.errorMsg)

func verifyContractBytecode*(
    trustedCodeHash: KeccakHash,
    bytecode: openArray[byte]): Result[void, string] =
  if trustedCodeHash == keccakHash(bytecode):
    ok()
  else:
    err("hash of bytecode doesn't match the expected code hash")

proc buildAccountsTableFromKeys(
    db: ReadOnlyStateDB,
    keys: openArray[AccountAndSlots]): TableRef[EthAddress, AccountData] {.raises: [RlpError].} =

  var accounts = newTable[EthAddress, AccountData]()

  for key in keys:
    let account = db.getAccount(key.address)
    let code = if key.codeLen > 0:
        db.AccountStateDB.kvt().get(account.codeHash.data)
      else: @[]
    var storage = newTable[UInt256, UInt256]()

    if code.len() > 0:
      for slot in key.slots:
        let slotKey = fromBytesBE(UInt256, slot)
        let (slotValue, slotExists) = db.getStorage(key.address, slotKey)
        if slotExists:
          storage[slotKey] = slotValue

    accounts[key.address] = AccountData(
        account: account,
        code: code,
        storage: storage)

  return accounts

proc verifyWitness*(
    trustedStateRoot: KeccakHash,
    witness: BlockWitness): Result[TableRef[EthAddress, AccountData], string] =
  if witness.len() == 0:
    return err("witness is empty")

  let db: CoreDbRef = newCoreDbRef(LegacyDbMemory)
  var tb = initTreeBuilder(witness, db, {wfEIP170}) # what flags to use here?

  try:
    let stateRoot = tb.buildTree()
    if stateRoot != trustedStateRoot:
      return err("witness stateRoot doesn't match trustedStateRoot")

    let ac = newAccountStateDB(db, trustedStateRoot, false)
    let accounts = buildAccountsTableFromKeys(ReadOnlyStateDB(ac), tb.keys)
    ok(accounts)
  except Exception as e:
    err(e.msg)

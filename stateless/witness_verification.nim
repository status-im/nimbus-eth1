# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/tables,
  stint,
  eth/[common, rlp],
  stew/results,
  ../nimbus/db/[core_db, state_db],
  ./[tree_from_witness, witness_types]

export results

type
  BlockWitness* = seq[byte]

  AccountData* = object
    account*: Account
    code*   : seq[byte]
    storage*: Table[UInt256, UInt256]

proc buildAccountsTableFromKeys(
    db: ReadOnlyStateDB,
    keys: openArray[AccountAndSlots]): TableRef[EthAddress, AccountData] {.raises: [RlpError].} =

  var accounts = newTable[EthAddress, AccountData]()

  for key in keys:
    let account = db.getAccount(key.address)
    let code = if key.codeLen > 0:
        db.getTrie().parent().kvt().get(account.codeHash.data)
      else: @[]
    var storage = initTable[UInt256, UInt256]()

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
    witness: BlockWitness,
    flags: WitnessFlags): Result[TableRef[EthAddress, AccountData], string] =
  if witness.len() == 0:
    return err("witness is empty")

  let db = newCoreDbRef(AristoDbMemory) # `AristoDbVoid` has smaller footprint
  var tb = initTreeBuilder(witness, db, flags)

  try:
    let stateRoot = tb.buildTree()
    if stateRoot != trustedStateRoot:
      return err("witness stateRoot doesn't match trustedStateRoot")

    let ac = newAccountStateDB(db, trustedStateRoot)
    let accounts = buildAccountsTableFromKeys(ReadOnlyStateDB(ac), tb.keys)
    ok(accounts)
  except Exception as e:
    err(e.msg)

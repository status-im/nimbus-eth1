# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[sets, strformat, typetraits],
  chronicles,
  eth/[common, rlp, trie/trie_defs],
  results,
  ../../constants,
  ../../utils/utils,
  ".."/[core_db, ledger, storage_types]

logScope:
  topics = "state_db"

# aleth/geth/parity compatibility mode:
#
# affected test cases both in GST and BCT:
# - stSStoreTest\InitCollision.json
# - stRevertTest\RevertInCreateInInit.json
# - stCreate2\RevertInCreateInInitCreate2.json
#
# pyEVM sided with original Nimbus EVM
#
# implementation difference:
# Aleth/geth/parity using accounts cache.
# When contract creation happened on an existing
# but 'empty' account with non empty storage will
# get new empty storage root.
# Aleth cs. only clear the storage cache while both pyEVM
# and Nimbus will modify the state trie.
# During the next SSTORE call, aleth cs. calculate
# gas used based on this cached 'original storage value'.
# In other hand pyEVM and Nimbus will fetch
# 'original storage value' from state trie.
#
# Both Yellow Paper and EIP2200 are not clear about this
# situation but since aleth/geth/and parity implement this
# behaviour, we perhaps also need to implement it.
#
# TODO: should this compatibility mode enabled via
# compile time switch, runtime switch, or just hard coded
# it?
const
  aleth_compat = true

type
  AccountStateDB* = ref object
    trie: AccountLedger
    originalRoot: KeccakHash   # will be updated for every transaction
    when aleth_compat:
      cleared: HashSet[EthAddress]

  #MptNodeRlpBytes* = seq[byte]
  #AccountProof* = seq[MptNodeRlpBytes]
  #SlotProof* = seq[MptNodeRlpBytes]

proc db*(db: AccountStateDB): CoreDbRef =
  db.trie.db

proc rootHash*(db: AccountStateDB): KeccakHash =
  db.trie.state

proc `rootHash=`*(db: AccountStateDB, root: KeccakHash) =
  db.trie = AccountLedger.init(db.trie.db, root)

func newCoreDbAccount(
    eAddr: EthAddress;
    nonce = AccountNonce(0);
    balance = 0.u256;
     ): CoreDbAccount =
  CoreDbAccount(
    address: eAddr,
    nonce:    nonce,
    balance:  balance,
    codeHash: EMPTY_CODE_HASH)

proc newAccountStateDB*(backingStore: CoreDbRef,
                        root: KeccakHash): AccountStateDB =
  result.new()
  result.trie = AccountLedger.init(backingStore, root)
  result.originalRoot = root
  when aleth_compat:
    result.cleared = initHashSet[EthAddress]()

#proc getTrie*(db: AccountStateDB): CoreDxMptRef =
#  db.trie.mpt

#proc getSecureTrie*(db: AccountStateDB): CoreDbPhkRef =
#  db.trie.phk

proc to*(acc: CoreDbAccount; T: type Account): T =
  ## Convert to legacy object, will throw an aseert if that fails
  let rc = acc.recast()
  if rc.isErr:
    raiseAssert "getAccount(): cannot convert account: " & $$rc.error
  rc.value

proc getAccount*(db: AccountStateDB, eAddr: EthAddress): CoreDbAccount =
  db.trie.fetch(eAddr).valueOr:
    return newCoreDbAccount(eAddr)

proc setAccount*(db: AccountStateDB, acc: CoreDbAccount) =
  db.trie.merge(acc)

proc deleteAccount*(db: AccountStateDB, acc: CoreDbAccount) =
  db.trie.delete(acc.address)

proc deleteAccount*(db: AccountStateDB, eAddr: EthAddress) =
  db.trie.delete(eAddr)

proc getCodeHash*(db: AccountStateDB, eAddr: EthAddress): Hash256 =
  db.getAccount(eAddr).codeHash

proc getBalance*(db: AccountStateDB, eAddr: EthAddress): UInt256 =
  db.getAccount(eAddr).balance

proc setBalance*(db: AccountStateDB, eAddr: EthAddress, balance: UInt256) =
  var acc = db.getAccount(eAddr)
  if acc.balance != balance:
    acc.balance = balance
    db.setAccount(acc)

proc addBalance*(db: AccountStateDB, eAddr: EthAddress, delta: UInt256) =
  db.setBalance(eAddr, db.getBalance(eAddr) + delta)

#template getStorageTrie(db: AccountStateDB, account: Account): auto =
#  storageTrieForAccount(db.trie, account)

proc subBalance*(db: AccountStateDB, eAddr: EthAddress, delta: UInt256) =
  db.setBalance(eAddr, db.getBalance(eAddr) - delta)

#template createTrieKeyFromSlot(slot: UInt256): auto =
#  # Converts a number to hex big-endian representation including
#  # prefix and leading zeros:
#  slot.toBytesBE
#  # Original py-evm code:
#  # pad32(int_to_big_endian(slot))
#  # morally equivalent to toByteRange_Unnecessary but with different types

proc clearStorage*(db: AccountStateDB, eAddr: EthAddress) =
  # Flush associated storage trie (will update account record on disk)
  db.trie.distinctBase.stoFlush(eAddr).isOkOr:
    raiseAssert "clearStorage():  stoFlush() failed, " & $$error
  # Reset storage info locally so that `Aristo` would not complain when
  # updating the account record on disk
  var account = db.getAccount(eAddr)
  account.storage = CoreDbColRef(nil)
  when aleth_compat:
    db.cleared.incl eAddr

proc getStorageRoot*(db: AccountStateDB, eAddr: EthAddress): Hash256 =
  db.getAccount(eAddr).storage.state.valueOr:
    EMPTY_ROOT_HASH

proc setStorage*(
    db: AccountStateDB;
    eAddr: EthAddress;
    slot: UInt256;
    value: UInt256;
      ) =
  var
    acc = db.getAccount(eAddr)
    sto = StorageLedger.init(db.trie, acc)

  if value > 0:
    sto.merge(slot, rlp.encode(value))
  else:
    sto.delete(slot)

  # map slot hash back to slot value
  # see iterator storage below
  var
    # slotHash can be obtained from storage.merge()?
    slotHash = keccakHash(slot.toBytesBE)
  db.db.newKvt().put(
    slotHashToSlotKey(slotHash.data).toOpenArray, rlp.encode(slot)).isOkOr:
      raiseAssert "setStorage(): put(slotHash) failed: " & $$error

  # Changing the storage trie might also change the `storage` descriptor when
  # the trie changes from empty to existing or v.v.
  acc.storage = sto.getColumn()

  # No need to hold descriptors for longer than needed
  let state = acc.storage.state.valueOr:
    raiseAssert "Storage column state error: " & $$error
  if state == EMPTY_ROOT_HASH:
    acc.storage = CoreDbColRef(nil)

iterator storage*(db: AccountStateDB, eAddr: EthAddress): (UInt256, UInt256) =
  let kvt = db.db.newKvt()
  for key, value in db.trie.storage db.getAccount(eAddr):
    if key.len != 0:
      var keyData = kvt.get(slotHashToSlotKey(key).toOpenArray).valueOr:
        raiseAssert "storage(): get() failed: " & $$error
      yield (rlp.decode(keyData, UInt256), rlp.decode(value, UInt256))

proc getStorage*(
    db: AccountStateDB;
    eAddr: EthAddress;
    slot: UInt256;
      ): Result[UInt256,void] =
  let
    acc = db.getAccount(eAddr)
    data = ? StorageLedger.init(db.trie, acc).fetch(slot)
  ok rlp.decode(data, UInt256)

proc setNonce*(db: AccountStateDB, eAddr: EthAddress; nonce: AccountNonce) =
  var acc = db.getAccount(eAddr)
  if nonce != acc.nonce:
    acc.nonce = nonce
    db.setAccount(acc)

proc getNonce*(db: AccountStateDB, eAddr: EthAddress): AccountNonce =
  db.getAccount(eAddr).nonce

proc incNonce*(db: AccountStateDB, eAddr: EthAddress) {.inline.} =
  db.setNonce(eAddr, db.getNonce(eAddr) + 1)

proc setCode*(db: AccountStateDB, eAddr: EthAddress, code: openArray[byte]) =
  var acc = db.getAccount(eAddr)
  let codeHash = keccakHash(code)
  if acc.codeHash != codeHash:
    if code.len != 0:
      db.db.newKvt().put(contractHashKey(codeHash).toOpenArray, code).isOkOr:
        raiseAssert "setCode(): put() failed: " & $$error
    acc.codeHash = codeHash
    db.setAccount(acc)

proc getCode*(db: AccountStateDB, eAddr: EthAddress): seq[byte] =
  let codeHash = db.getCodeHash(eAddr)
  db.db.newKvt().get(contractHashKey(codeHash).toOpenArray).valueOr:
    EmptyBlob

proc contractCollision*(db: AccountStateDB, eAddr: EthAddress): bool =
  db.getNonce(eAddr) != 0 or
    db.getCodeHash(eAddr) != EMPTY_CODE_HASH or
      db.getStorageRoot(eAddr) != EMPTY_ROOT_HASH

proc dumpAccount*(db: AccountStateDB, eAddr: string): string =
  let pAddr = eAddr.parseAddress
  return fmt"{eAddr}: Storage: {db.getStorage(pAddr, 0.u256)}; getAccount: {db.getAccount pAddr}"

proc accountExists*(db: AccountStateDB, eAddr: EthAddress): bool =
  db.trie.fetch(eAddr).isOk

proc isEmptyAccount*(db: AccountStateDB, eAddr: EthAddress): bool =
  let acc = db.trie.fetch(eAddr).valueOr:
    return false
  acc.nonce == 0 and
    acc.balance.isZero and
    acc.codeHash == EMPTY_CODE_HASH

proc isDeadAccount*(db: AccountStateDB, eAddr: EthAddress): bool =
  let acc = db.trie.fetch(eAddr).valueOr:
    return true
  acc.nonce == 0 and
    acc.balance.isZero and
    acc.codeHash == EMPTY_CODE_HASH

#proc removeEmptyRlpNode(branch: var seq[MptNodeRlpBytes]) =
#  if branch.len() == 1 and branch[0] == emptyRlp:
#    branch.del(0)

#proc getAccountProof*(db: AccountStateDB, eAddr: EthAddress): AccountProof =
#  var branch = db.trie.phk().getBranch(eAddr)
#  removeEmptyRlpNode(branch)
#  branch

#proc getStorageProof*(db: AccountStateDB, eAddr: EthAddress, slots: seq[UInt256]): seq[SlotProof] =
#  var acc = db.getAccount(eAddr)
#  var storageTrie = StorageLedger.init(db.trie, acc)
#
#  var slotProofs = newSeqOfCap[SlotProof](slots.len())
#  for slot in slots:
#    var branch = storageTrie.phk().getBranch(createTrieKeyFromSlot(slot))
#    removeEmptyRlpNode(branch)
#    slotProofs.add(branch)
#
#  slotProofs

# Note: `state_db.getCommittedStorage()` is nowhere used.
#
#proc getCommittedStorage*(db: AccountStateDB, eAddr: EthAddress, slot: UInt256): UInt256 =
#  let tmpHash = db.rootHash
#  db.rootHash = db.originalRoot
#  db.transactionID.shortTimeReadOnly():
#    when aleth_compat:
#      if eAddr in db.cleared:
#        debug "Forced contract creation on existing account detected", eAddr
#        result = 0.u256
#      else:
#        result = db.getStorage(eAddr, slot)[0]
#    else:
#      result = db.getStorage(eAddr, slot)[0]
#  db.rootHash = tmpHash

# Note: `state_db.updateOriginalRoot()` is nowhere used.
#
#proc updateOriginalRoot*(db: AccountStateDB) =
#  ## this proc will be called for every transaction
#  db.originalRoot = db.rootHash
#  # no need to rollback or dispose
#  # transactionID, it will be handled elsewhere
#  db.transactionID = db.db.getTransactionID()
#
#  when aleth_compat:
#    db.cleared.clear()

# End

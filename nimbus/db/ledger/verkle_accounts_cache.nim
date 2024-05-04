# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables, hashes, sets],
  chronicles,
  eth/common,
  ../../../stateless/multi_keys,
  ../../constants,
  ../../utils/utils,
  ../access_list as ac_access_list,
  "../../../vendor/nim-eth-verkle/eth_verkle"/[
    math,
    tree/tree
  ],
  ../verkle/verkle_accounts,
  ".."/[core_db, verkle_distinct_tries, transient_storage]


const
  debugAccountsCache = false

## Rewrite of AccountsCache as per the Verkle Specs, Notable changes:
## 1) No storage trie, as storage is now a part of the unified Verkle Trie (EIP 6800)
## 2) Changing the format of Witness Data and Witness Cache
## 3) Changing the trie in AccountsCache to a VerkleTrie

type
  AccountFlag = enum
    Alive
    IsNew
    Dirty
    Touched
    CodeLoaded
    CodeChanged
    StorageChanged
    NewlyCreated # EIP-6780: self destruct only in same transaction

  AccountFlags = set[AccountFlag]

  RefAccount = ref object
    account: Account
    flags: AccountFlags
    code: seq[byte]
    originalStorage: TableRef[UInt256, UInt256]
    overlayStorage: Table[UInt256, UInt256]


  ## Needs to be replaced with the ExecutionWitness used in Verkle Trees:
  ## Format:
  ##  ExecutionWitness:
  ##    StateDiff 
  ##    VerkleProof (rootHash)
  ## 
  WitnessData* = object
    storageKeys*: HashSet[UInt256]
    codeTouched*: bool

  AccountsCache* = ref object
    trie: VerkleTrie
    savePoint: SavePoint
    witnessCache: Table[EthAddress, WitnessData]
    isDirty: bool
    ripemdSpecial: bool

  ReadOnlyStateDB* = distinct AccountsCache

  TransactionState = enum
    Pending
    Committed
    RolledBack

  SavePoint* = ref object
    parentSavepoint: SavePoint
    cache: Table[EthAddress, RefAccount]
    selfDestruct: HashSet[EthAddress]
    logEntries: seq[Log]
    accessList: ac_access_list.AccessList
    transientStorage: TransientStorage
    state: TransactionState
    when debugAccountsCache:
      depth: int

const
  emptyAcc = newAccount()

  resetFlags = {
    Dirty,
    IsNew,
    Touched,
    CodeChanged,
    StorageChanged,
    NewlyCreated
    }

when debugAccountsCache:
  import
    stew/byteutils

  proc inspectSavePoint(name: string, x: SavePoint) =
    debugEcho "*** ", name, ": ", x.depth, " ***"
    var sp = x
    while sp != nil:
      for address, acc in sp.cache:
        debugEcho address.toHex, " ", acc.flags
      sp = sp.parentSavepoint

proc beginSavePoint*(ac: AccountsCache): SavePoint {.gcsafe.}

proc rawTrie*(ac: AccountsCache): VerkleTrie {.inline.} = ac.trie

proc init*(x: typedesc[AccountsCache]): AccountsCache =
  new result
  result.trie = initVerkleTrie()
  result.witnessCache = initTable[EthAddress, WitnessData]
  discard result.beginSavePoint

proc rootHash*(ac: AccountsCache): KeccakHash =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # make sure all cache already committed
  doAssert(ac.isDirty == false)
  result.data = VerkleTrieRef(ac.trie).hashVerkleTrie()

proc isTopLevelClean*(ac: AccountsCache): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ac.isDirty and ac.savePoint.parentSavepoint.isNil

proc beginSavepoint*(ac: AccountsCache): SavePoint =
  new result
  result.cache = initTable[EthAddress, RefAccount]()
  result.accessList.init()
  result.transientStorage.init()
  result.state = Pending
  result.parentSavepoint = ac.savePoint
  ac.savePoint = result

  when debugAccountsCache:
    if not result.parentSavePoint.isNil:
      result.depth = result.parentSavePoint.depth + 1
    inspectSavePoint("snapshot", result)

proc rollback*(ac: AccountsCache, sp: SavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  ac.savePoint = sp.parentSavepoint
  sp.state = RolledBack

  when debugAccountsCache:
    inspectSavePoint("rollback", ac.savePoint)

proc commit*(ac: AccountsCache, sp: SavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  # cannot commit most inner savepoint
  doAssert not sp.parentSavepoint.isNil

  ac.savePoint = sp.parentSavepoint
  for k, v in sp.cache:
    sp.parentSavepoint.cache[k] = v

  ac.savePoint.transientStorage.merge(sp.transientStorage)
  ac.savePoint.accessList.merge(sp.accessList)
  ac.savePoint.selfDestruct.incl sp.selfDestruct
  ac.savePoint.logEntries.add sp.logEntries
  sp.state = Committed

  when debugAccountsCache:
    inspectSavePoint("commit", ac.savePoint)

proc dispose*(ac: AccountsCache, sp: SavePoint) {.inline.} =
  if sp.state == Pending:
    ac.rollback(sp)

proc safeDispose*(ac: AccountsCache, sp: SavePoint) {.inline.} =
  if (not isNil(sp)) and (sp.state == Pending):
    ac.rollback(sp)

proc getAccount(ac: AccountsCache, address: EthAddress, shouldCreate = true): RefAccount =
  # look for account from layers of cache
  var sp = ac.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      return
    sp = sp.parentSavepoint

  let account = ac.trie.getAccountBytes(address)

  # Check if the account fetched from the Verkle Trie is Empty or not
  if (not account.isEmptyVerkleAccount()):
    result = RefAccount(
      account: account,
      flags: {Alive}
    )

  else:
    if not shouldCreate:
      return
    # it's a request for new account
    result = RefAccount(
      account: newAccount(),
      flags: {Alive, IsNew}
      )
  
  # cache the account
  ac.savePoint.cache[address] = result


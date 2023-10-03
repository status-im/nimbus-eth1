# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common,
  ../../../../stateless/multi_keys,
  "../.."/[core_db, distinct_tries],
  ".."/[accounts_cache, base, base/base_desc]

type
  WrappedAccountsCache* = ref object of LedgerRef

  WrappedSavePoint* = ref object of LedgerSpRef
    sp: SavePoint

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template noRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    raiseAssert info & ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""

func savePoint(sp: LedgerSpRef): SavePoint =
  sp.WrappedSavePoint.sp

# ----------------
  
proc ledgerMethods(lc: AccountsCache): LedgerFns =
  LedgerFns(
    accessListFn: proc(eAddr: EthAddress) =
      lc.accessList(eAddr),

    accessList2Fn: proc(eAddr: EthAddress, slot: UInt256) =
      lc.accessList(eAddr, slot),

    accountExistsFn: proc(eAddr: EthAddress): bool =
      lc.accountExists(eAddr),

    addBalanceFn: proc(eAddr: EthAddress, delta: UInt256) =
      lc.addBalance(eAddr, delta),

    addLogEntryFn: proc(log: Log) =
      lc.addLogEntry(log),

    beginSavepointFn: proc(): LedgerSpRef =
      WrappedSavePoint(sp: lc.beginSavepoint()),
  
    clearStorageFn: proc(eAddr: EthAddress) =
      lc.clearStorage(eAddr),

    clearTransientStorageFn: proc() =
      lc.clearTransientStorage(),

    collectWitnessDataFn: proc() =
      lc.collectWitnessData(),

    commitFn: proc(sp: LedgerSpRef) =
      lc.commit(sp.savePoint),

    deleteAccountFn: proc(eAddr: EthAddress) =
      lc.deleteAccount(eAddr),

    disposeFn: proc(sp: LedgerSpRef) =
      lc.dispose(sp.savePoint),

    getAndClearLogEntriesFn: proc(): seq[Log] =
      lc.getAndClearLogEntries(),

    getBalanceFn: proc(eAddr: EthAddress): UInt256 =
      lc.getBalance(eAddr),

    getCodeFn: proc(eAddr: EthAddress): Blob =
      lc.getCode(eAddr),

    getCodeHashFn: proc(eAddr: EthAddress): Hash256 =
      lc.getCodeHash(eAddr),

    getCodeSizeFn: proc(eAddr: EthAddress): int =
      lc.getCodeSize(eAddr),

    getCommittedStorageFn: proc(eAddr: EthAddress, slot: UInt256): UInt256 =
      noRlpException "getCommittedStorage()":
        result = lc.getCommittedStorage(eAddr, slot)
      discard,

    getNonceFn: proc(eAddr: EthAddress): AccountNonce =
      lc.getNonce(eAddr),

    getStorageFn: proc(eAddr: EthAddress, slot: UInt256): UInt256 =
      noRlpException "getStorageFn()":
        result = lc.getStorage(eAddr, slot)
      discard,

    getStorageRootFn: proc(eAddr: EthAddress): Hash256 =
      lc.getStorageRoot(eAddr),

    getTransientStorageFn: proc(eAddr: EthAddress, slot: UInt256): UInt256 =
      lc.getTransientStorage(eAddr, slot),

    hasCodeOrNonceFn: proc(eAddr: EthAddress): bool =
      lc.hasCodeOrNonce(eAddr),

    inAccessListFn: proc(eAddr: EthAddress): bool =
      lc.inAccessList(eAddr),

    inAccessList2Fn: proc(eAddr: EthAddress, slot: UInt256): bool =
      lc.inAccessList(eAddr, slot),

    incNonceFn: proc(eAddr: EthAddress) =
      lc.incNonce(eAddr),

    isDeadAccountFn: proc(eAddr: EthAddress): bool =
      lc.isDeadAccount(eAddr),

    isEmptyAccountFn: proc(eAddr: EthAddress): bool =
      lc.isEmptyAccount(eAddr),

    isTopLevelCleanFn: proc(): bool =
      lc.isTopLevelClean(),

    logEntriesFn: proc(): seq[Log] =
      lc.logEntries(),

    makeMultiKeysFn: proc(): MultikeysRef =
      lc.makeMultiKeys(),

    persistFn: proc(clearEmptyAccount: bool, clearCache: bool) =
      lc.persist(clearEmptyAccount, clearCache),

    ripemdSpecialFn: proc() =
      lc.ripemdSpecial(),

    rollbackFn: proc(sp: LedgerSpRef) =
      lc.rollback(sp.savePoint),

    rootHashFn: proc(): Hash256 =
      lc.rootHash(),

    safeDisposeFn: proc(sp: LedgerSpRef) =
      lc.safeDispose(sp.savePoint),

    selfDestruct6780Fn: proc(eAddr: EthAddress) =
      lc.selfDestruct(eAddr),

    selfDestructFn: proc(eAddr: EthAddress) =
      lc.selfDestruct6780(eAddr),

    selfDestructLenFn: proc(): int =
      lc.selfDestructLen(),

    setBalanceFn: proc(eAddr: EthAddress, balance: UInt256) =
      lc.setBalance(eAddr, balance),

    setCodeFn: proc(eAddr: EthAddress, code: Blob) =
      lc.setCode(eAddr, code),

    setNonceFn: proc(eAddr: EthAddress, nonce: AccountNonce) =
      lc.setNonce(eAddr, nonce),

    setStorageFn: proc(eAddr: EthAddress, slot, val: UInt256) =
      noRlpException "setStorage()":
        lc.setStorage(eAddr, slot, val)
      discard,

    setTransientStorageFn: proc(eAddr: EthAddress, slot, val: UInt256) =
      lc.setTransientStorage(eAddr, slot, val),

    subBalanceFn: proc(eAddr: EthAddress, delta: UInt256) =
      lc.subBalance(eAddr, delta))

proc ledgerIterators(lc: AccountsCache): LedgerIterators =
  LedgerIterators(
    accountsIt: iterator(): Account =
      for w in lc.accounts():
        yield w
      discard,
                  
    addressesIt: iterator(): EthAddress =
      for w in lc.addresses():
        yield w
      discard,
        
    cachedStorageIt: iterator(eAddr: EthAddress): (UInt256,UInt256) =
      for w in lc.cachedStorage(eAddr):
        yield w
      discard,

    pairsIt: iterator(): (EthAddress,Account) =
      for w in lc.pairs():
        yield w
      discard,

    storageIt: iterator(eAddr: EthAddress): (UInt256,UInt256)
        {.gcsafe, raises: [CoreDbApiError].} =
      noRlpException "storage()":
        for w in lc.storage(eAddr):
          yield w
      discard)

proc ledgerExtras(lc: AccountsCache): LedgerExtras =
  LedgerExtras(
    rawRootHashFn: proc(): Hash256 =
      lc.rawTrie.rootHash())

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type WrappedAccountsCache;
    db: CoreDbRef;
    root: Hash256;
    pruneTrie: bool): LedgerRef =
  let lc = AccountsCache.init(db, root, pruneTrie)
  result = T(
    ldgType:   LegacyAccountsCache,

    extras:    lc.ledgerExtras(),
    iterators: lc.ledgerIterators(),
    methods:   lc.ledgerMethods())
  result.validate

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

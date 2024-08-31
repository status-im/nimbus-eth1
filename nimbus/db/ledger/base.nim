# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Ledger management APIs.

{.push raises: [].}

import
  eth/common,
  ../../evm/code_bytes,
  ../../stateless/multi_keys,
  ../core_db,
  ./backend/accounts_ledger,
  ./base/[api_tracking, base_config, base_desc]

type
  ReadOnlyStateDB* = distinct LedgerRef

export
  code_bytes,
  LedgerRef,
  LedgerSpRef

# ------------------------------------------------------------------------------
# Logging/tracking helpers (some public)
# ------------------------------------------------------------------------------

when LedgerEnableApiTracking:
  import
    std/times,
    chronicles
  logScope:
    topics = "ledger"
  const
    apiTxt = "API"

when LedgerEnableApiProfiling:
  export
    LedgerFnInx,
    LedgerProfListRef

# ------------------------------------------------------------------------------
# Public methods
# ------------------------------------------------------------------------------

proc accessList*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgAccessListFn
  ldg.ac.accessList(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr)

proc accessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256) =
  ldg.beginTrackApi LdgAccessListFn
  ldg.ac.accessList(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), slot

proc accountExists*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgAccountExistsFn
  result = ldg.ac.accountExists(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc addBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.beginTrackApi LdgAddBalanceFn
  ldg.ac.addBalance(eAddr, delta)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), delta

proc addLogEntry*(ldg: LedgerRef, log: Log) =
  ldg.beginTrackApi LdgAddLogEntryFn
  ldg.ac.addLogEntry(log)
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc beginSavepoint*(ldg: LedgerRef): LedgerSpRef =
  ldg.beginTrackApi LdgBeginSavepointFn
  result = ldg.ac.beginSavepoint()
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc clearStorage*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgClearStorageFn
  ldg.ac.clearStorage(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr)

proc clearTransientStorage*(ldg: LedgerRef) =
  ldg.beginTrackApi LdgClearTransientStorageFn
  ldg.ac.clearTransientStorage()
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc collectWitnessData*(ldg: LedgerRef) =
  ldg.beginTrackApi LdgCollectWitnessDataFn
  ldg.ac.collectWitnessData()
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc commit*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgCommitFn
  ldg.ac.commit(sp)
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc deleteAccount*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgDeleteAccountFn
  ldg.ac.deleteAccount(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr)

proc dispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgDisposeFn
  ldg.ac.dispose(sp)
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc getAndClearLogEntries*(ldg: LedgerRef): seq[Log] =
  ldg.beginTrackApi LdgGetAndClearLogEntriesFn
  result = ldg.ac.getAndClearLogEntries()
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc getBalance*(ldg: LedgerRef, eAddr: EthAddress): UInt256 =
  ldg.beginTrackApi LdgGetBalanceFn
  result = ldg.ac.getBalance(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc getCode*(ldg: LedgerRef, eAddr: EthAddress): CodeBytesRef =
  ldg.beginTrackApi LdgGetCodeFn
  result = ldg.ac.getCode(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc getCodeHash*(ldg: LedgerRef, eAddr: EthAddress): Hash256  =
  ldg.beginTrackApi LdgGetCodeHashFn
  result = ldg.ac.getCodeHash(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result=($$result)

proc getCodeSize*(ldg: LedgerRef, eAddr: EthAddress): int =
  ldg.beginTrackApi LdgGetCodeSizeFn
  result = ldg.ac.getCodeSize(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc getCommittedStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
      ): UInt256 =
  ldg.beginTrackApi LdgGetCommittedStorageFn
  result = ldg.ac.getCommittedStorage(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), slot, result

proc getNonce*(ldg: LedgerRef, eAddr: EthAddress): AccountNonce =
  ldg.beginTrackApi LdgGetNonceFn
  result = ldg.ac.getNonce(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc getStorage*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): UInt256 =
  ldg.beginTrackApi LdgGetStorageFn
  result = ldg.ac.getStorage(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), slot, result

proc getStorageRoot*(ldg: LedgerRef, eAddr: EthAddress): Hash256 =
  ldg.beginTrackApi LdgGetStorageRootFn
  result = ldg.ac.getStorageRoot(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result=($$result)

proc getTransientStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
      ): UInt256 =
  ldg.beginTrackApi LdgGetTransientStorageFn
  result = ldg.ac.getTransientStorage(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), slot, result

proc contractCollision*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgContractCollisionFn
  result = ldg.ac.contractCollision(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgInAccessListFn
  result = ldg.ac.inAccessList(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): bool =
  ldg.beginTrackApi LdgInAccessListFn
  result = ldg.ac.inAccessList(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), slot, result

proc incNonce*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgIncNonceFn
  ldg.ac.incNonce(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr)

proc isDeadAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgIsDeadAccountFn
  result = ldg.ac.isDeadAccount(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc isEmptyAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgIsEmptyAccountFn
  result = ldg.ac.isEmptyAccount(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), result

proc isTopLevelClean*(ldg: LedgerRef): bool =
  ldg.beginTrackApi LdgIsTopLevelCleanFn
  result = ldg.ac.isTopLevelClean()
  ldg.ifTrackApi: debug apiTxt, api, elapsed, result

proc makeMultiKeys*(ldg: LedgerRef): MultiKeysRef =
  ldg.beginTrackApi LdgMakeMultiKeysFn
  result = ldg.ac.makeMultiKeys()
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc persist*(ldg: LedgerRef, clearEmptyAccount = false, clearCache = false) =
  ldg.beginTrackApi LdgPersistFn
  ldg.ac.persist(clearEmptyAccount, clearCache)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, clearEmptyAccount, clearCache

proc ripemdSpecial*(ldg: LedgerRef) =
  ldg.beginTrackApi LdgRipemdSpecialFn
  ldg.ac.ripemdSpecial()
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc rollback*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgRollbackFn
  ldg.ac.rollback(sp)
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc safeDispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgSafeDisposeFn
  ldg.ac.safeDispose(sp)
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc selfDestruct*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgSelfDestructFn
  ldg.ac.selfDestruct(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc selfDestruct6780*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgSelfDestruct6780Fn
  ldg.ac.selfDestruct6780(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc selfDestructLen*(ldg: LedgerRef): int =
  ldg.beginTrackApi LdgSelfDestructLenFn
  result = ldg.ac.selfDestructLen()
  ldg.ifTrackApi: debug apiTxt, api, elapsed, result

proc setBalance*(ldg: LedgerRef, eAddr: EthAddress, balance: UInt256) =
  ldg.beginTrackApi LdgSetBalanceFn
  ldg.ac.setBalance(eAddr, balance)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), balance

proc setCode*(ldg: LedgerRef, eAddr: EthAddress, code: Blob) =
  ldg.beginTrackApi LdgSetCodeFn
  ldg.ac.setCode(eAddr, code)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), code

proc setNonce*(ldg: LedgerRef, eAddr: EthAddress, nonce: AccountNonce) =
  ldg.beginTrackApi LdgSetNonceFn
  ldg.ac.setNonce(eAddr, nonce)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), nonce

proc setStorage*(ldg: LedgerRef, eAddr: EthAddress, slot, val: UInt256) =
  ldg.beginTrackApi LdgSetStorageFn
  ldg.ac.setStorage(eAddr, slot, val)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), slot, val

proc setTransientStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
    val: UInt256;
      ) =
  ldg.beginTrackApi LdgSetTransientStorageFn
  ldg.ac.setTransientStorage(eAddr, slot, val)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), slot, val

proc state*(ldg: LedgerRef): Hash256 =
  ldg.beginTrackApi LdgStateFn
  result = ldg.ac.state()
  ldg.ifTrackApi: debug apiTxt, api, elapsed, result

proc subBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.beginTrackApi LdgSubBalanceFn
  ldg.ac.subBalance(eAddr, delta)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, eAddr=($$eAddr), delta

proc getAccessList*(ldg: LedgerRef): AccessList =
  ldg.beginTrackApi LdgGetAccessListFn
  result = ldg.ac.getAccessList()
  ldg.ifTrackApi: debug apiTxt, api, elapsed

proc rootHash*(ldg: LedgerRef): KeccakHash =
  ldg.state()

proc getEthAccount*(ldg: LedgerRef, eAddr: EthAddress): Account =
  ldg.beginTrackApi LdgGetAthAccountFn
  result = ldg.ac.getEthAccount(eAddr)
  ldg.ifTrackApi: debug apiTxt, api, elapsed, result

# ------------------------------------------------------------------------------
# Public virtual read-only methods
# ------------------------------------------------------------------------------

proc rootHash*(db: ReadOnlyStateDB): KeccakHash = db.LedgerRef.state()
proc getCodeHash*(db: ReadOnlyStateDB, eAddr: EthAddress): Hash256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, eAddr: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, eAddr: EthAddress): UInt256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, eAddr: EthAddress, slot: UInt256): UInt256 {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, eAddr: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, eAddr: EthAddress): CodeBytesRef {.borrow.}
proc getCodeSize*(db: ReadOnlyStateDB, eAddr: EthAddress): int {.borrow.}
proc contractCollision*(db: ReadOnlyStateDB, eAddr: EthAddress): bool {.borrow.}
proc accountExists*(db: ReadOnlyStateDB, eAddr: EthAddress): bool {.borrow.}
proc isDeadAccount*(db: ReadOnlyStateDB, eAddr: EthAddress): bool {.borrow.}
proc isEmptyAccount*(db: ReadOnlyStateDB, eAddr: EthAddress): bool {.borrow.}
proc getCommittedStorage*(db: ReadOnlyStateDB, eAddr: EthAddress, slot: UInt256): UInt256 {.borrow.}
func inAccessList*(db: ReadOnlyStateDB, eAddr: EthAddress): bool {.borrow.}
func inAccessList*(db: ReadOnlyStateDB, eAddr: EthAddress, slot: UInt256): bool {.borrow.}
func getTransientStorage*(db: ReadOnlyStateDB, eAddr: EthAddress, slot: UInt256): UInt256 {.borrow.}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

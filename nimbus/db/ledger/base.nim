# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Unify different ledger management APIs.

{.push raises: [].}

import
  eth/common,
  ../../../stateless/multi_keys,
  ../core_db,
  ./base/[base_desc, validate]

type
  ReadOnlyStateDB* = distinct LedgerRef

export
  LedgerType,
  LedgerRef,
  LedgerSpRef

const
  AutoValidateDescriptors = defined(release).not

  EnableApiTracking = true and false
    ## When enabled, API functions are logged. Tracking is enabled by setting
    ## the `trackApi` flag to `true`.

  apiTxt = "Ledger API"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when EnableApiTracking:
  {.warning: "*** Provided API logging for Ledger (disabled by default)".}

  import
    std/times,
    chronicles,
    base/api_tracking

  proc `$`(a: EthAddress): string {.used.} = a.toStr
  proc `$`(e: Duration): string {.used.} = e.toStr

template beginTrackApi(ldg: LedgerRef; s: static[string]) =
  when EnableApiTracking:
    ldg.beginApi
    let ctx {.inject.} = s

template ifTrackApi(ldg: LedgerRef; code: untyped) =
  when EnableApiTracking:
    ldg.endApiIf: code

# ------------------------------------------------------------------------------
# Public constructor helper
# ------------------------------------------------------------------------------

proc bless*(ldg: LedgerRef; db: CoreDbRef): LedgerRef =
  ldg.beginTrackApi "LedgerRef.init()"
  when AutoValidateDescriptors:
    ldg.validate()
  when EnableApiTracking:
    ldg.trackApi = db.trackLedgerApi
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, ldgType=ldg.ldgType
  ldg

# ------------------------------------------------------------------------------
# Public methods
# ------------------------------------------------------------------------------

proc accessList*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi "accessList()"
  ldg.methods.accessListFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc accessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256) =
  ldg.beginTrackApi "accessList()"
  ldg.methods.accessList2Fn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot

proc accountExists*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi "accountExists()"
  result = ldg.methods.accountExistsFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc addBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.beginTrackApi "addBalance()"
  ldg.methods.addBalanceFn(eAddr, delta)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, delta

proc addLogEntry*(ldg: LedgerRef, log: Log) =
  ldg.beginTrackApi "addLogEntry()"
  ldg.methods.addLogEntryFn log
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc beginSavepoint*(ldg: LedgerRef): LedgerSpRef =
  ldg.beginTrackApi "beginSavepoint()"
  result = ldg.methods.beginSavepointFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc clearStorage*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi "clearStorage()"
  ldg.methods.clearStorageFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc clearTransientStorage*(ldg: LedgerRef) =
  ldg.beginTrackApi "clearTransientStorage()"
  ldg.methods.clearTransientStorageFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc collectWitnessData*(ldg: LedgerRef) =
  ldg.beginTrackApi "collectWitnessData()"
  ldg.methods.collectWitnessDataFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc commit*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi "commit()"
  ldg.methods.commitFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc deleteAccount*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi "deleteAccount()"
  ldg.methods.deleteAccountFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc dispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi "dispose()"
  ldg.methods.disposeFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc getAndClearLogEntries*(ldg: LedgerRef): seq[Log] =
  ldg.beginTrackApi "getAndClearLogEntries()"
  result = ldg.methods.getAndClearLogEntriesFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc getBalance*(ldg: LedgerRef, eAddr: EthAddress): UInt256 =
  ldg.beginTrackApi "getBalance()"
  result = ldg.methods.getBalanceFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getCode*(ldg: LedgerRef, eAddr: EthAddress): Blob =
  ldg.beginTrackApi "getCode()"
  result = ldg.methods.getCodeFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result=result.toStr

proc getCodeHash*(ldg: LedgerRef, eAddr: EthAddress): Hash256  =
  ldg.beginTrackApi "getCodeHash()"
  result = ldg.methods.getCodeHashFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result=result.toStr

proc getCodeSize*(ldg: LedgerRef, eAddr: EthAddress): int =
  ldg.beginTrackApi "getCodeSize()"
  result = ldg.methods.getCodeSizeFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getCommittedStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
      ): UInt256 =
  ldg.beginTrackApi "getCommittedStorage()"
  result = ldg.methods.getCommittedStorageFn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc getNonce*(ldg: LedgerRef, eAddr: EthAddress): AccountNonce =
  ldg.beginTrackApi "getNonce()"
  result = ldg.methods.getNonceFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getStorage*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): UInt256 =
  ldg.beginTrackApi "getStorage()"
  result = ldg.methods.getStorageFn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc getStorageRoot*(ldg: LedgerRef, eAddr: EthAddress): Hash256 =
  ldg.beginTrackApi "getStorageRoot()"
  result = ldg.methods.getStorageRootFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result=result.toStr

proc getTransientStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
      ): UInt256 =
  ldg.beginTrackApi "getTransientStorage()"
  result = ldg.methods.getTransientStorageFn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc hasCodeOrNonce*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi "hasCodeOrNonce()"
  result = ldg.methods.hasCodeOrNonceFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi "inAccessList()"
  result = ldg.methods.inAccessListFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): bool =
  ldg.beginTrackApi "inAccessList()"
  result = ldg.methods.inAccessList2Fn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc incNonce*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi "incNonce()"
  ldg.methods.incNonceFn(eAddr)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc isDeadAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi "isDeadAccount()"
  result = ldg.methods.isDeadAccountFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc isEmptyAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi "isEmptyAccount()"
  result = ldg.methods.isEmptyAccountFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc isTopLevelClean*(ldg: LedgerRef): bool =
  ldg.beginTrackApi "isTopLevelClean()"
  result = ldg.methods.isTopLevelCleanFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

proc logEntries*(ldg: LedgerRef): seq[Log] =
  ldg.beginTrackApi "logEntries()"
  result = ldg.methods.logEntriesFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result=result.toStr

proc makeMultiKeys*(ldg: LedgerRef): MultikeysRef =
  ldg.beginTrackApi "makeMultiKeys()"
  result = ldg.methods.makeMultiKeysFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc persist*(ldg: LedgerRef, clearEmptyAccount = false, clearCache = true) =
  ldg.beginTrackApi "persist()"
  ldg.methods.persistFn(clearEmptyAccount, clearCache)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, clearEmptyAccount, clearCache

proc ripemdSpecial*(ldg: LedgerRef) =
  ldg.beginTrackApi "ripemdSpecial()"
  ldg.methods.ripemdSpecialFn()
  ldg.ifTrackApi: debug apiTxt, ctx

proc rollback*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi "rollback()"
  ldg.methods.rollbackFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc rootHash*(ldg: LedgerRef): Hash256 =
  ldg.beginTrackApi "rootHash()"
  result = ldg.methods.rootHashFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result=result.toStr

proc safeDispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi "safeDispose()"
  ldg.methods.safeDisposeFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc selfDestruct*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi "selfDestruct()"
  ldg.methods.selfDestructFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc selfDestruct6780*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi "selfDestruct6780()"
  ldg.methods.selfDestruct6780Fn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc selfDestructLen*(ldg: LedgerRef): int =
  ldg.beginTrackApi "selfDestructLen()"
  result = ldg.methods.selfDestructLenFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

proc setBalance*(ldg: LedgerRef, eAddr: EthAddress, balance: UInt256) =
  ldg.beginTrackApi "setBalance()"
  ldg.methods.setBalanceFn(eAddr, balance)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, balance

proc setCode*(ldg: LedgerRef, eAddr: EthAddress, code: Blob) =
  ldg.beginTrackApi "setCode()"
  ldg.methods.setCodeFn(eAddr, code)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, code=code.toStr

proc setNonce*(ldg: LedgerRef, eAddr: EthAddress, nonce: AccountNonce) =
  ldg.beginTrackApi "setNonce()"
  ldg.methods.setNonceFn(eAddr, nonce)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, nonce

proc setStorage*(ldg: LedgerRef, eAddr: EthAddress, slot, val: UInt256) =
  ldg.beginTrackApi "setStorage()"
  ldg.methods.setStorageFn(eAddr, slot, val)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, val

proc setTransientStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
    val: UInt256;
      ) =
  ldg.beginTrackApi "setTransientStorage()"
  ldg.methods.setTransientStorageFn(eAddr, slot, val)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, val

proc subBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.beginTrackApi "setTransientStorage()"
  ldg.methods.subBalanceFn(eAddr, delta)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, delta

# ------------------------------------------------------------------------------
# Public methods, extensions to go away
# ------------------------------------------------------------------------------

proc getMpt*(ldg: LedgerRef): CoreDbMptRef =
  ldg.beginTrackApi "getMpt()"
  result = ldg.extras.getMptFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result=result.toStr

proc rawRootHash*(ldg: LedgerRef): Hash256 =
  ldg.beginTrackApi "rawRootHash()"
  result = ldg.extras.rawRootHashFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result=result.toStr

# ------------------------------------------------------------------------------
# Public virtual read-only methods
# ------------------------------------------------------------------------------

proc rootHash*(db: ReadOnlyStateDB): KeccakHash {.borrow.}
proc getCodeHash*(db: ReadOnlyStateDB, eAddr: EthAddress): Hash256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, eAddr: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, eAddr: EthAddress): UInt256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, eAddr: EthAddress, slot: UInt256): UInt256 {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, eAddr: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, eAddr: EthAddress): seq[byte] {.borrow.}
proc getCodeSize*(db: ReadOnlyStateDB, eAddr: EthAddress): int {.borrow.}
proc hasCodeOrNonce*(db: ReadOnlyStateDB, eAddr: EthAddress): bool {.borrow.}
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

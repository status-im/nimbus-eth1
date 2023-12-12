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
  ./base/[api_tracking, base_desc]

const
  AutoValidateDescriptors = defined(release).not
    ## No validatinon needed for production suite.

  EnableApiTracking = false
    ## When enabled, API functions are logged. Tracking is enabled by setting
    ## the `trackApi` flag to `true`.

  EnableApiProfiling = true
    ## Enable functions profiling (only if `EnableApiTracking` is set `true`.)

  apiTxt = "Ledger API"


type
  ReadOnlyStateDB* = distinct LedgerRef

export
  LedgerType,
  LedgerRef,
  LedgerSpRef,

  # Profiling support
  byElapsed,
  byMean,
  byVisits,
  stats

const
  LedgerEnableApiTracking* = EnableApiTracking
  LedgerEnableApiProfiling* = EnableApiTracking and EnableApiProfiling
  LedgerApiTxt* = apiTxt

when EnableApiTracking and EnableApiProfiling:
  var ledgerProfTab*: LedgerProfFnInx


when AutoValidateDescriptors:
  import ./base/validate

# ------------------------------------------------------------------------------
# Logging/tracking helpers (some public)
# ------------------------------------------------------------------------------

when EnableApiTracking:
  when EnableApiProfiling:
    {.warning: "*** Provided API profiling for Ledger (disabled by default)".}
  else:
    {.warning: "*** Provided API logging for Ledger (disabled by default)".}

  import
    std/times,
    chronicles

  func `$`(e: Duration): string {.used.} = e.toStr
  func `$`(c: CoreDbMptRef): string {.used.} = c.toStr
  func `$`(l: seq[Log]): string {.used.} = l.toStr
  func `$`(h: Hash256): string {.used.} = h.toStr
  func `$`(a: EthAddress): string {.used.} = a.toStr

# Publicly available for API logging
template beginTrackApi*(ldg: LedgerRef; s: LedgerFnInx) =
  when EnableApiTracking:
    ldg.beginApi
    let ctx {.inject.} = s

template ifTrackApi*(ldg: LedgerRef; code: untyped) =
  when EnableApiTracking:
    ldg.endApiIf:
      when EnableApiProfiling:
        ledgerProfTab.update(ctx, elapsed)
      code

# ------------------------------------------------------------------------------
# Public constructor helper
# ------------------------------------------------------------------------------

proc bless*(ldg: LedgerRef; db: CoreDbRef): LedgerRef =
  ldg.beginTrackApi LdgBlessFn
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
  ldg.beginTrackApi LdgAccessListFn
  ldg.methods.accessListFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc accessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256) =
  ldg.beginTrackApi LdgAccessListFn
  ldg.methods.accessList2Fn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot

proc accountExists*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgAccountExistsFn
  result = ldg.methods.accountExistsFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc addBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.beginTrackApi LdgAddBalanceFn
  ldg.methods.addBalanceFn(eAddr, delta)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, delta

proc addLogEntry*(ldg: LedgerRef, log: Log) =
  ldg.beginTrackApi LdgAddLogEntryFn
  ldg.methods.addLogEntryFn log
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc beginSavepoint*(ldg: LedgerRef): LedgerSpRef =
  ldg.beginTrackApi LdgBeginSavepointFn
  result = ldg.methods.beginSavepointFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc clearStorage*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgClearStorageFn
  ldg.methods.clearStorageFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc clearTransientStorage*(ldg: LedgerRef) =
  ldg.beginTrackApi LdgClearTransientStorageFn
  ldg.methods.clearTransientStorageFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc collectWitnessData*(ldg: LedgerRef) =
  ldg.beginTrackApi LdgCollectWitnessDataFn
  ldg.methods.collectWitnessDataFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc commit*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgCommitFn
  ldg.methods.commitFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc deleteAccount*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgDeleteAccountFn
  ldg.methods.deleteAccountFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc dispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgDisposeFn
  ldg.methods.disposeFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc getAndClearLogEntries*(ldg: LedgerRef): seq[Log] =
  ldg.beginTrackApi LdgGetAndClearLogEntriesFn
  result = ldg.methods.getAndClearLogEntriesFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc getBalance*(ldg: LedgerRef, eAddr: EthAddress): UInt256 =
  ldg.beginTrackApi LdgGetBalanceFn
  result = ldg.methods.getBalanceFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getCode*(ldg: LedgerRef, eAddr: EthAddress): Blob =
  ldg.beginTrackApi LdgGetCodeFn
  result = ldg.methods.getCodeFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result=result.toStr

proc getCodeHash*(ldg: LedgerRef, eAddr: EthAddress): Hash256  =
  ldg.beginTrackApi LdgGetCodeHashFn
  result = ldg.methods.getCodeHashFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getCodeSize*(ldg: LedgerRef, eAddr: EthAddress): int =
  ldg.beginTrackApi LdgGetCodeSizeFn
  result = ldg.methods.getCodeSizeFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getCommittedStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
      ): UInt256 =
  ldg.beginTrackApi LdgGetCommittedStorageFn
  result = ldg.methods.getCommittedStorageFn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc getNonce*(ldg: LedgerRef, eAddr: EthAddress): AccountNonce =
  ldg.beginTrackApi LdgGetNonceFn
  result = ldg.methods.getNonceFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getStorage*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): UInt256 =
  ldg.beginTrackApi LdgGetStorageFn
  result = ldg.methods.getStorageFn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc getStorageRoot*(ldg: LedgerRef, eAddr: EthAddress): Hash256 =
  ldg.beginTrackApi LdgGetStorageRootFn
  result = ldg.methods.getStorageRootFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc getTransientStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
      ): UInt256 =
  ldg.beginTrackApi LdgGetTransientStorageFn
  result = ldg.methods.getTransientStorageFn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc hasCodeOrNonce*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgHasCodeOrNonceFn
  result = ldg.methods.hasCodeOrNonceFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgInAccessListFn
  result = ldg.methods.inAccessListFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): bool =
  ldg.beginTrackApi LdgInAccessListFn
  result = ldg.methods.inAccessList2Fn(eAddr, slot)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, result

proc incNonce*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgIncNonceFn
  ldg.methods.incNonceFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr

proc isDeadAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgIsDeadAccountFn
  result = ldg.methods.isDeadAccountFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc isEmptyAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.beginTrackApi LdgIsEmptyAccountFn
  result = ldg.methods.isEmptyAccountFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, result

proc isTopLevelClean*(ldg: LedgerRef): bool =
  ldg.beginTrackApi LdgIsTopLevelCleanFn
  result = ldg.methods.isTopLevelCleanFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

proc logEntries*(ldg: LedgerRef): seq[Log] =
  ldg.beginTrackApi LdgLogEntriesFn
  result = ldg.methods.logEntriesFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

proc makeMultiKeys*(ldg: LedgerRef): MultikeysRef =
  ldg.beginTrackApi LdgMakeMultiKeysFn
  result = ldg.methods.makeMultiKeysFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc persist*(ldg: LedgerRef, clearEmptyAccount = false, clearCache = true) =
  ldg.beginTrackApi LdgPersistFn
  ldg.methods.persistFn(clearEmptyAccount, clearCache)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, clearEmptyAccount, clearCache

proc ripemdSpecial*(ldg: LedgerRef) =
  ldg.beginTrackApi LdgRipemdSpecialFn
  ldg.methods.ripemdSpecialFn()
  ldg.ifTrackApi: debug apiTxt, ctx

proc rollback*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgRollbackFn
  ldg.methods.rollbackFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc rootHash*(ldg: LedgerRef): Hash256 =
  ldg.beginTrackApi LdgRootHashFn
  result = ldg.methods.rootHashFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

proc safeDispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.beginTrackApi LdgSafeDisposeFn
  ldg.methods.safeDisposeFn sp
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc selfDestruct*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgSelfDestructFn
  ldg.methods.selfDestructFn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc selfDestruct6780*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.beginTrackApi LdgSelfDestruct6780Fn
  ldg.methods.selfDestruct6780Fn eAddr
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed

proc selfDestructLen*(ldg: LedgerRef): int =
  ldg.beginTrackApi LdgSelfDestructLenFn
  result = ldg.methods.selfDestructLenFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

proc setBalance*(ldg: LedgerRef, eAddr: EthAddress, balance: UInt256) =
  ldg.beginTrackApi LdgSetBalanceFn
  ldg.methods.setBalanceFn(eAddr, balance)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, balance

proc setCode*(ldg: LedgerRef, eAddr: EthAddress, code: Blob) =
  ldg.beginTrackApi LdgSetCodeFn
  ldg.methods.setCodeFn(eAddr, code)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, code=code.toStr

proc setNonce*(ldg: LedgerRef, eAddr: EthAddress, nonce: AccountNonce) =
  ldg.beginTrackApi LdgSetNonceFn
  ldg.methods.setNonceFn(eAddr, nonce)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, nonce

proc setStorage*(ldg: LedgerRef, eAddr: EthAddress, slot, val: UInt256) =
  ldg.beginTrackApi LdgSetStorageFn
  ldg.methods.setStorageFn(eAddr, slot, val)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, val

proc setTransientStorage*(
    ldg: LedgerRef;
    eAddr: EthAddress;
    slot: UInt256;
    val: UInt256;
      ) =
  ldg.beginTrackApi LdgSetTransientStorageFn
  ldg.methods.setTransientStorageFn(eAddr, slot, val)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, slot, val

proc subBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.beginTrackApi LdgSubBalanceFn
  ldg.methods.subBalanceFn(eAddr, delta)
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, eAddr, delta

# ------------------------------------------------------------------------------
# Public methods, extensions to go away
# ------------------------------------------------------------------------------

proc getMpt*(ldg: LedgerRef): CoreDbMptRef =
  ldg.beginTrackApi LdgGetMptFn
  result = ldg.extras.getMptFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

proc rawRootHash*(ldg: LedgerRef): Hash256 =
  ldg.beginTrackApi LdgRawRootHashFn
  result = ldg.extras.rawRootHashFn()
  ldg.ifTrackApi: debug apiTxt, ctx, elapsed, result

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

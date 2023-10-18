# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  ./base/[base_desc, validate]

type
  ReadOnlyStateDB* = distinct LedgerRef

export
  LedgerType,
  LedgerRef,
  LedgerSpRef

when defined(release):
  const AutoValidateDescriptors = false
else:
  const AutoValidateDescriptors = true

# ------------------------------------------------------------------------------
# Public constructor helper
# ------------------------------------------------------------------------------

when AutoValidateDescriptors:
  proc validate*(ldg: LedgerRef) =
    validate.validate(ldg)
else:
  template validate*(ldg: LedgerRef) =
    discard

# ------------------------------------------------------------------------------
# Public methods
# ------------------------------------------------------------------------------

proc accessList*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.methods.accessListFn(eAddr)

proc accessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256) =
  ldg.methods.accessList2Fn(eAddr, slot)

proc accountExists*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.methods.accountExistsFn(eAddr)

proc addBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.methods.addBalanceFn(eAddr, delta)

proc addLogEntry*(ldg: LedgerRef, log: Log) =
  ldg.methods.addLogEntryFn(log)

proc beginSavepoint*(ldg: LedgerRef): LedgerSpRef =
  ldg.methods.beginSavepointFn()

proc clearStorage*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.methods.clearStorageFn(eAddr)

proc clearTransientStorage*(ldg: LedgerRef) =
  ldg.methods.clearTransientStorageFn()

proc collectWitnessData*(ldg: LedgerRef) =
  ldg.methods.collectWitnessDataFn()

proc commit*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.methods.commitFn(sp)

proc deleteAccount*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.methods.deleteAccountFn(eAddr)

proc dispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.methods.disposeFn(sp)

proc getAndClearLogEntries*(ldg: LedgerRef): seq[Log] =
  ldg.methods.getAndClearLogEntriesFn()

proc getBalance*(ldg: LedgerRef, eAddr: EthAddress): UInt256 =
  ldg.methods.getBalanceFn(eAddr)

proc getCode*(ldg: LedgerRef, eAddr: EthAddress): Blob =
  ldg.methods.getCodeFn(eAddr)

proc getCodeHash*(ldg: LedgerRef, eAddr: EthAddress): Hash256  =
  ldg.methods.getCodeHashFn(eAddr)

proc getCodeSize*(ldg: LedgerRef, eAddr: EthAddress): int =
  ldg.methods.getCodeSizeFn(eAddr)

proc getCommittedStorage*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): UInt256 =
  ldg.methods.getCommittedStorageFn(eAddr, slot)

proc getNonce*(ldg: LedgerRef, eAddr: EthAddress): AccountNonce =
  ldg.methods.getNonceFn(eAddr)

proc getStorage*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): UInt256 =
  ldg.methods.getStorageFn(eAddr, slot)

proc getStorageRoot*(ldg: LedgerRef, eAddr: EthAddress): Hash256 =
  ldg.methods.getStorageRootFn(eAddr)

proc getTransientStorage*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): UInt256 =
  ldg.methods.getTransientStorageFn(eAddr, slot)

proc hasCodeOrNonce*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.methods.hasCodeOrNonceFn(eAddr)

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.methods.inAccessListFn(eAddr)

proc inAccessList*(ldg: LedgerRef, eAddr: EthAddress, slot: UInt256): bool =
  ldg.methods.inAccessList2Fn(eAddr, slot)

proc incNonce*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.methods.incNonceFn(eAddr)

proc isDeadAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.methods.isDeadAccountFn(eAddr)

proc isEmptyAccount*(ldg: LedgerRef, eAddr: EthAddress): bool =
  ldg.methods.isEmptyAccountFn(eAddr)

proc isTopLevelClean*(ldg: LedgerRef): bool =
  ldg.methods.isTopLevelCleanFn()

proc logEntries*(ldg: LedgerRef): seq[Log] =
  ldg.methods.logEntriesFn()

proc makeMultiKeys*(ldg: LedgerRef): MultikeysRef =
  ldg.methods.makeMultiKeysFn()

proc persist*(ldg: LedgerRef, clearEmptyAccount = false, clearCache = true) =
  ldg.methods.persistFn(clearEmptyAccount, clearCache)

proc ripemdSpecial*(ldg: LedgerRef) =
  ldg.methods.ripemdSpecialFn()

proc rollback*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.methods.rollbackFn(sp)

proc rootHash*(ldg: LedgerRef): Hash256 =
  ldg.methods.rootHashFn()

proc safeDispose*(ldg: LedgerRef, sp: LedgerSpRef) =
  ldg.methods.safeDisposeFn(sp)

proc selfDestruct*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.methods.selfDestructFn(eAddr)

proc selfDestruct6780*(ldg: LedgerRef, eAddr: EthAddress) =
  ldg.methods.selfDestruct6780Fn(eAddr)

proc selfDestructLen*(ldg: LedgerRef): int =
  ldg.methods.selfDestructLenFn()

proc setBalance*(ldg: LedgerRef, eAddr: EthAddress, balance: UInt256) =
  ldg.methods.setBalanceFn(eAddr, balance)

proc setCode*(ldg: LedgerRef, eAddr: EthAddress, code: Blob) =
  ldg.methods.setCodeFn(eAddr, code)

proc setNonce*(ldg: LedgerRef, eAddr: EthAddress, nonce: AccountNonce) =
  ldg.methods.setNonceFn(eAddr, nonce)

proc setStorage*(ldg: LedgerRef, eAddr: EthAddress, slot, val: UInt256) =
  ldg.methods.setStorageFn(eAddr, slot, val)

proc setTransientStorage*(ldg: LedgerRef, eAddr: EthAddress, slot, val: UInt256) =
  ldg.methods.setTransientStorageFn(eAddr, slot, val)

proc subBalance*(ldg: LedgerRef, eAddr: EthAddress, delta: UInt256) =
  ldg.methods.subBalanceFn(eAddr, delta)

# ------------------------------------------------------------------------------
# Public methods, extensions to go away
# ------------------------------------------------------------------------------

proc rawRootHash*(ldg: LedgerRef): Hash256 =
  ldg.extras.rawRootHashFn()

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

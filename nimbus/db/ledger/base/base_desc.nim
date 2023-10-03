# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/common,
  ../../../../stateless/multi_keys,
  ../../../errors

# Annotation helpers
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: apiRaise, gcsafe, raises: [CoreDbApiError].}

type
  LedgerType* = enum
    Ooops = 0
    LegacyAccountsCache,
    LedgerCacheMethods

  LedgerSpRef* = ref object of RootRef
    ## Object for check point or save point

  LedgerRef* = ref object of RootRef
    ## Root object with closures
    ldgType*: LedgerType    ## For debugging
    extras*: LedgerExtras   ## Support might go away
    iterators*: LedgerIterators
    methods*: LedgerFns

  RawRootHashFn* = proc(): Hash256 {.noRaise.}

  LedgerExtras* = object
    rawRootHashFn*: RawRootHashFn

  AccountsIt* = iterator(): Account {.noRaise.}
  AddressesIt* = iterator(): EthAddress {.noRaise.}
  CachedStorageIt* = iterator(eAddr: EthAddress): (UInt256,UInt256) {.noRaise.}
  PairsIt* = iterator(): (EthAddress, Account) {.noRaise.}
  StorageIt* = iterator(eAddr: EthAddress): (UInt256,UInt256) {.apiRaise.}

  LedgerIterators* = object
    accountsIt*: AccountsIt
    addressesIt*: AddressesIt
    cachedStorageIt*: CachedStorageIt
    pairsIt*: PairsIt
    storageIt*: StorageIt

  AccessListFn* = proc(eAddr: EthAddress) {.noRaise.}
  AccessList2Fn* = proc(eAddr: EthAddress, slot: UInt256) {.noRaise.}
  AccountExistsFn* = proc(eAddr: EthAddress): bool {.noRaise.}
  AddBalanceFn* = proc(eAddr: EthAddress, delta: UInt256) {.noRaise.}
  AddLogEntryFn* = proc(log: Log) {.noRaise.}
  BeginSavepointFn* = proc(): LedgerSpRef {.noRaise.}
  ClearStorageFn* = proc(eAddr: EthAddress) {.noRaise.}
  ClearTransientStorageFn* = proc() {.noRaise.}
  CollectWitnessDataFn* = proc() {.noRaise.}
  CommitFn* = proc(sp: LedgerSpRef) {.noRaise.}
  DeleteAccountFn* = proc(eAddr: EthAddress) {.noRaise.}
  DisposeFn* = proc(sp: LedgerSpRef) {.noRaise.}
  GetAndClearLogEntriesFn* = proc(): seq[Log] {.noRaise.}
  GetBalanceFn* = proc(eAddr: EthAddress): UInt256 {.noRaise.}
  GetCodeFn* = proc(eAddr: EthAddress): Blob {.noRaise.}
  GetCodeHashFn* = proc(eAddr: EthAddress): Hash256 {.noRaise.}
  GetCodeSizeFn* = proc(eAddr: EthAddress): int {.noRaise.}
  GetCommittedStorageFn* =
    proc(eAddr: EthAddress, slot: UInt256): UInt256 {.noRaise.}
  GetNonceFn* = proc(eAddr: EthAddress): AccountNonce {.noRaise.}
  GetStorageFn* = proc(eAddr: EthAddress, slot: UInt256): UInt256 {.noRaise.}
  GetStorageRootFn* = proc(eAddr: EthAddress): Hash256 {.noRaise.}
  GetTransientStorageFn* =
    proc(eAddr: EthAddress, slot: UInt256): UInt256 {.noRaise.}
  HasCodeOrNonceFn* = proc(eAddr: EthAddress): bool {.noRaise.}
  InAccessListFn* = proc(eAddr: EthAddress): bool {.noRaise.}
  InAccessList2Fn* = proc(eAddr: EthAddress, slot: UInt256): bool {.noRaise.}
  IncNonceFn* = proc(eAddr: EthAddress) {.noRaise.}
  IsDeadAccountFn* = proc(eAddr: EthAddress): bool {.noRaise.}
  IsEmptyAccountFn* = proc(eAddr: EthAddress): bool {.noRaise.}
  IsTopLevelCleanFn* = proc(): bool {.noRaise.}
  LogEntriesFn* = proc(): seq[Log] {.noRaise.}
  MakeMultiKeysFn* = proc(): MultikeysRef {.noRaise.}
  PersistFn* = proc(clearEmptyAccount: bool, clearCache: bool) {.noRaise.}
  RipemdSpecialFn* = proc() {.noRaise.}
  RollbackFn* = proc(sp: LedgerSpRef) {.noRaise.}
  RootHashFn* = proc(): Hash256 {.noRaise.}
  SafeDisposeFn* = proc(sp: LedgerSpRef) {.noRaise.}
  SelfDestructFn* = proc(eAddr: EthAddress) {.noRaise.}
  SelfDestruct6780Fn* = proc(eAddr: EthAddress) {.noRaise.}
  SelfDestructLenFn* = proc(): int {.noRaise.}
  SetBalanceFn* = proc(eAddr: EthAddress, balance: UInt256) {.noRaise.}
  SetCodeFn* = proc(eAddr: EthAddress, code: Blob) {.noRaise.}
  SetNonceFn* = proc(eAddr: EthAddress, nonce: AccountNonce) {.noRaise.}
  SetStorageFn* = proc(eAddr: EthAddress, slot, value: UInt256) {.noRaise.}
  SetTransientStorageFn* =
    proc(eAddr: EthAddress, slot, val: UInt256) {.noRaise.}
  SubBalanceFn* = proc(eAddr: EthAddress, delta: UInt256) {.noRaise.}

  LedgerFns* = object
    accessListFn*: AccessListFn
    accessList2Fn*: AccessList2Fn
    accountExistsFn*: AccountExistsFn
    addBalanceFn*: AddBalanceFn
    addLogEntryFn*: AddLogEntryFn
    beginSavepointFn*: BeginSavepointFn
    clearStorageFn*: ClearStorageFn
    clearTransientStorageFn*: ClearTransientStorageFn
    collectWitnessDataFn*: CollectWitnessDataFn
    commitFn*: CommitFn
    deleteAccountFn*: DeleteAccountFn
    disposeFn*: DisposeFn
    getAndClearLogEntriesFn*: GetAndClearLogEntriesFn
    getBalanceFn*: GetBalanceFn
    getCodeFn*: GetCodeFn
    getCodeHashFn*: GetCodeHashFn
    getCodeSizeFn*: GetCodeSizeFn
    getCommittedStorageFn*: GetCommittedStorageFn
    getNonceFn*: GetNonceFn
    getStorageFn*: GetStorageFn
    getStorageRootFn*: GetStorageRootFn
    getTransientStorageFn*: GetTransientStorageFn
    hasCodeOrNonceFn*: HasCodeOrNonceFn
    inAccessListFn*: InAccessListFn
    inAccessList2Fn*: InAccessList2Fn
    incNonceFn*: IncNonceFn
    isDeadAccountFn*: IsDeadAccountFn
    isEmptyAccountFn*: IsEmptyAccountFn
    isTopLevelCleanFn*: IsTopLevelCleanFn
    logEntriesFn*: LogEntriesFn
    makeMultiKeysFn*: MakeMultiKeysFn
    persistFn*: PersistFn
    ripemdSpecialFn*: RipemdSpecialFn
    rollbackFn*: RollbackFn
    rootHashFn*: RootHashFn
    safeDisposeFn*: SafeDisposeFn
    selfDestruct6780Fn*: SelfDestruct6780Fn
    selfDestructFn*: SelfDestructFn
    selfDestructLenFn*: SelfDestructLenFn
    setBalanceFn*: SetBalanceFn
    setCodeFn*: SetCodeFn
    setNonceFn*: SetNonceFn
    setStorageFn*: SetStorageFn
    setTransientStorageFn*: SetTransientStorageFn
    subBalanceFn*: SubBalanceFn

# End

# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[strutils, times],
  eth/common,
  stew/byteutils,
  ../../aristo/aristo_profile,
  ../../core_db,
  "."/base_desc

type
  LedgerFnInx* = enum
    ## Profiling table index
    SummaryItem                = "total"

    LdgBlessFn                 = "LedgerRef.init"

    LdgAccessListFn            = "accessList"
    LdgAccountExistsFn         = "accountExists"
    LdgAddBalanceFn            = "addBalance"
    LdgAddLogEntryFn           = "addLogEntry"
    LdgBeginSavepointFn        = "beginSavepoint"
    LdgClearStorageFn          = "clearStorage"
    LdgClearTransientStorageFn = "clearTransientStorage"
    LdgCollectWitnessDataFn    = "collectWitnessData"
    LdgCommitFn                = "commit"
    LdgContractCollisionFn     = "contractCollision"
    LdgDeleteAccountFn         = "deleteAccount"
    LdgDisposeFn               = "dispose"
    LdgGetAccessListFn         = "getAcessList"
    LdgGetAccountFn            = "getAccount"
    LdgGetAndClearLogEntriesFn = "getAndClearLogEntries"
    LdgGetBalanceFn            = "getBalance"
    LdgGetCodeFn               = "getCode"
    LdgGetCodeHashFn           = "getCodeHash"
    LdgGetCodeSizeFn           = "getCodeSize"
    LdgGetCommittedStorageFn   = "getCommittedStorage"
    LdgGetMptFn                = "getMpt"
    LdgGetNonceFn              = "getNonce"
    LdgGetStorageFn            = "getStorage"
    LdgGetStorageRootFn        = "getStorageRoot"
    LdgGetTransientStorageFn   = "getTransientStorage"
    LdgGetAthAccountFn         = "getEthAccount"
    LdgInAccessListFn          = "inAccessList"
    LdgIncNonceFn              = "incNonce"
    LdgIsDeadAccountFn         = "isDeadAccount"
    LdgIsEmptyAccountFn        = "isEmptyAccount"
    LdgIsTopLevelCleanFn       = "isTopLevelClean"
    LdgLogEntriesFn            = "logEntries"
    LdgMakeMultiKeysFn         = "makeMultiKeys"
    LdgPersistFn               = "persist"
    LdgRawRootHashFn           = "rawRootHash"
    LdgRipemdSpecialFn         = "ripemdSpecial"
    LdgRollbackFn              = "rollback"
    LdgRootHashFn              = "rootHash"
    LdgSafeDisposeFn           = "safeDispose"
    LdgSelfDestruct6780Fn      = "selfDestruct6780"
    LdgSelfDestructFn          = "selfDestruct"
    LdgSelfDestructLenFn       = "selfDestructLen"
    LdgSetBalanceFn            = "setBalance"
    LdgSetCodeFn               = "setCode"
    LdgSetNonceFn              = "setNonce"
    LdgSetStorageFn            = "setStorage"
    LdgSetTransientStorageFn   = "setTransientStorage"
    LdgStateFn                 = "state"
    LdgSubBalanceFn            = "subBalance"

    LdgAccountsIt              = "accounts"
    LdgAdressesIt              = "addresses"
    LdgCachedStorageIt         = "cachedStorage"
    LdgPairsIt                 = "pairs"
    LdgStorageIt               = "storage"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func oaToStr(w: openArray[byte]): string =
  w.toHex.toLowerAscii

# ------------------------------------------------------------------------------
# Public API logging helpers
# ------------------------------------------------------------------------------

func toStr*(w: EthAddress): string =
  w.oaToStr

func toStr*(w: Hash256): string =
  w.data.oaToStr

when declared(CoreDbMptRef):
  func toStr*(w: CoreDbMptRef): string =
    if w.CoreDxMptRef.isNil: "MptRef(nil)" else: "MptRef"

func toStr*(w: Blob): string =
  if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
  else: "Blob[" & $w.len & "]"

func toStr*(w: seq[Log]): string =
  "Logs[" & $w.len & "]"

func toStr*(ela: Duration): string =
  aristo_profile.toStr(ela)

# ------------------------------------------------------------------------------
# Public API logging framework
# ------------------------------------------------------------------------------

template beginApi*(ldg: LedgerRef; s: static[LedgerFnInx]) =
  const api {.inject,used.} = s      # Generally available
  let baStart {.inject.} = getTime() # Local use only

template endApiIf*(ldg: LedgerRef; code: untyped) =
  when CoreDbEnableApiProfiling:
    let elapsed {.inject,used.} = getTime() - baStart
    aristo_profile.update(ldg.profTab, api.ord, elapsed)
  if ldg.trackApi:
    when not CoreDbEnableApiProfiling: # otherwise use variable above
      let elapsed {.inject,used.} = getTime() - baStart
    code

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func init*(T: type LedgerProfListRef): T =
  T(list: newSeq[LedgerProfData](1 + high(LedgerFnInx).ord))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

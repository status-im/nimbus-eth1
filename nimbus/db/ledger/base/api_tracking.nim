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
  ../../../evm/code_bytes,
  ../../aristo/aristo_profile,
  ../../core_db,
  "."/[base_config, base_desc]

type
  Elapsed* = distinct Duration
    ## Needed for local `$` as it would be ambiguous for `Duration`

  LedgerFnInx* = enum
    ## Profiling table index
    SummaryItem                = "total"

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
    LdgMakeMultiKeysFn         = "makeMultiKeys"
    LdgPersistFn               = "persist"
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

func toStr(w: Address): string =
  w.toHex

func toStr(w: Hash32): string =
  w.toHex

func toStr(w: CodeBytesRef): string =
  if w.isNil: "nil"
  else: "[" & $w.bytes.len & "]"

func toStr(w: seq[byte]): string =
  if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
  else: "seq[byte][" & $w.len & "]"

func toStr(w: seq[Log]): string =
  "Logs[" & $w.len & "]"

func toStr(ela: Duration): string =
  aristo_profile.toStr(ela)

# ------------------------------------------------------------------------------
# Public API logging helpers
# ------------------------------------------------------------------------------

func `$`*(w: CodeBytesRef): string {.used.} = w.toStr
func `$`*(e: Elapsed): string = e.Duration.toStr
func `$`*(l: seq[Log]): string = l.toStr
func `$`*(b: seq[byte]): string = b.toStr
func `$$`*(a: Address): string = a.toStr # otherwise collision w/existing `$`
func `$$`*(h: Hash32): string = h.toStr     # otherwise collision w/existing `$`

# ------------------------------------------------------------------------------
# Public API logging framework
# ------------------------------------------------------------------------------

template beginTrackApi*(ldg: LedgerRef; s: LedgerFnInx) =
  when LedgerEnableApiTracking:
    const api {.inject,used.} = s      # Generally available
    let baStart {.inject.} = getTime() # Local use only

template ifTrackApi*(ldg: LedgerRef; code: untyped) =
  when LedgerEnableApiTracking:
    when LedgerEnableApiProfiling:
      let elapsed {.inject,used.} = (getTime() - baStart).Elapsed
      aristo_profile.update(ldg.profTab, api.ord, elapsed.Duration)
    if ldg.trackApi:
      when not LedgerEnableApiProfiling: # otherwise use variable above
        let elapsed {.inject,used.} = (getTime() - baStart).Elapsed
      code

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func init*(T: type LedgerProfListRef): T =
  T(list: newSeq[LedgerProfData](1 + high(LedgerFnInx).ord))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

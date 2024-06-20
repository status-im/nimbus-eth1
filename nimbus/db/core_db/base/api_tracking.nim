# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strutils, times, typetraits],
  eth/common,
  results,
  stew/byteutils,
  ../../aristo/aristo_profile,
  ./base_desc

type
  CoreDbApiTrackRef* =
    CoreDbRef | CoreDbKvtRef | CoreDbColRef |
    CoreDbCtxRef | CoreDbMptRef | CoreDbAccRef |
    CoreDbTxRef | CoreDbCaptRef | CoreDbErrorRef

  CoreDbFnInx* = enum
    ## Profiling table index
    SummaryItem         = "total"

    AccDeleteFn         = "acc/delete"
    AccFetchFn          = "acc/fetch"
    AccForgetFn         = "acc/forget"
    AccHasPathFn        = "acc/hasPath"
    AccMergeFn          = "acc/merge"
    AccStateFn          = "acc/state"
    AccClearStorageFn   = "acc/clearStorage"

    AccSlotFetchFn      = "slotFetch"
    AccSlotDeleteFn     = "slotDelete"
    AccSlotHasPathFn    = "slotHasPath"
    AccSlotMergeFn      = "slotMerge"
    AccSlotStateFn      = "slotState"
    AccSlotPairsIt      = "slotPairs"

    AnyBackendFn        = "any/backend"

    BaseColPrintFn      = "$$"
    BaseColStateEmptyFn = "stateEmpty"
    BaseColStateFn      = "state"
    BaseDbTypeFn        = "dbType"
    BaseFinishFn        = "finish"
    BaseLevelFn         = "level"
    BaseNewCaptureFn    = "newCapture"
    BaseNewCtxFn        = "ctx"
    BaseNewCtxFromTxFn  = "ctxFromTx"
    BaseNewKvtFn        = "newKvt"
    BaseNewTxFn         = "newTransaction"
    BasePersistentFn    = "persistent"
    BaseSwapCtxFn       = "swapCtx"

    CptFlagsFn          = "cpt/flags"
    CptLogDbFn          = "cpt/logDb"
    CptRecorderFn       = "cpt/recorder"
    CptForgetFn         = "cpt/forget"

    CtxForgetFn         = "ctx/forget"
    CtxGetAccountsFn    = "getAccounts"
    CtxGetColumnFn      = "getColumn"
    CtxNewColFn         = "ctx/newColumn"

    ErrorPrintFn        = "$$"
    EthAccRecastFn      = "recast"

    KvtDelFn            = "del"
    KvtForgetFn         = "forget"
    KvtGetFn            = "get"
    KvtGetOrEmptyFn     = "getOrEmpty"
    KvtHasKeyFn         = "hasKey"
    KvtLenFn            = "len"
    KvtPairsIt          = "pairs"
    KvtPutFn            = "put"

    MptDeleteFn         = "mpt/delete"
    MptFetchFn          = "mpt/fetch"
    MptFetchOrEmptyFn   = "mpt/fetchOrEmpty"
    MptForgetFn         = "mpt/forget"
    MptHasPathFn        = "mpt/hasPath"
    MptMergeFn          = "mpt/merge"
    MptPairsIt          = "mpt/pairs"
    MptReplicateIt      = "mpt/replicate"
    MptStateFn          = "mpt/state"

    TxCommitFn          = "commit"
    TxDisposeFn         = "dispose"
    TxLevelFn           = "level"
    TxRollbackFn        = "rollback"
    TxSaveDisposeFn     = "safeDispose"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func oaToStr(w: openArray[byte]): string =
  w.toHex.toLowerAscii

# ------------------------------------------------------------------------------
# Public API logging helpers
# ------------------------------------------------------------------------------

func toStr*(w: Hash256): string =
  if w == EMPTY_ROOT_HASH: "EMPTY_ROOT_HASH" else: w.data.oaToStr

proc toStr*(e: CoreDbErrorRef): string =
  $e.error & "(" & e.parent.methods.errorPrintFn(e) & ")"

proc toStr*(p: CoreDbColRef): string =
  let
    w = if p.isNil or not p.ready: "nil" else: p.parent.methods.colPrintFn(p)
    (a,b) = if 0 < w.len and w[0] == '(': ("","") else: ("(",")")
  "Col" & a & w & b

func toLenStr*(w: openArray[byte]): string =
  if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
  else: "openArray[" & $w.len & "]"

func toLenStr*(w: Blob): string =
  if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
  else: "Blob[" & $w.len & "]"

func toStr*(w: openArray[byte]): string =
  w.oaToStr

func toStr*(w: set[CoreDbCaptFlags]): string =
  "Flags[" & $w.len & "]"

proc toStr*(rc: CoreDbRc[bool]): string =
  if rc.isOk: "ok(" & $rc.value & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[void]): string =
  if rc.isOk: "ok()" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[Blob]): string =
  if rc.isOk: "ok(Blob[" & $rc.value.len & "])"
  else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[Hash256]): string =
  if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[CoreDbColRef]): string =
  if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[set[CoreDbCaptFlags]]): string =
  if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[Account]): string =
  if rc.isOk: "ok(Account)" else: "err(" & rc.error.toStr & ")"

proc toStr[T](rc: CoreDbRc[T]; ifOk: static[string]): string =
  if rc.isOk: "ok(" & ifOk & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[CoreDbRef]): string = rc.toStr "db"
proc toStr*(rc: CoreDbRc[CoreDbAccount]): string = rc.toStr "acc"
proc toStr*(rc: CoreDbRc[CoreDbKvtRef]): string = rc.toStr "kvt"
proc toStr*(rc: CoreDbRc[CoreDbTxRef]): string = rc.toStr "tx"
proc toStr*(rc: CoreDbRc[CoreDbCaptRef]): string = rc.toStr "capt"
proc toStr*(rc: CoreDbRc[CoreDbCtxRef]): string = rc.toStr "ctx"
proc toStr*(rc: CoreDbRc[CoreDbMptRef]): string = rc.toStr "mpt"
proc toStr*(rc: CoreDbRc[CoreDbAccRef]): string = rc.toStr "acc"

func toStr*(ela: Duration): string =
  aristo_profile.toStr(ela)

# ------------------------------------------------------------------------------
# Public new API logging framework
# ------------------------------------------------------------------------------

template beginNewApi*(w: CoreDbApiTrackRef; s: static[CoreDbFnInx]) =
  when CoreDbEnableApiProfiling:
    const bnaCtx {.inject.} = s       # Local use only
  let bnaStart {.inject.} = getTime() # Local use only

template endNewApiIf*(w: CoreDbApiTrackRef; code: untyped) =
  block:
    when typeof(w) is CoreDbRef:
      let db = w
    else:
      if w.isNil: break
      let db = w.parent
    when CoreDbEnableApiProfiling:
      let elapsed {.inject,used.} = getTime() - bnaStart
      aristo_profile.update(db.profTab, bnaCtx.ord, elapsed)
    if db.trackNewApi:
      when not CoreDbEnableApiProfiling: # otherwise use variable above
        let elapsed {.inject,used.} = getTime() - bnaStart
      code

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func init*(T: type CoreDbProfListRef): T =
  T(list: newSeq[CoreDbProfData](1 + high(CoreDbFnInx).ord))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

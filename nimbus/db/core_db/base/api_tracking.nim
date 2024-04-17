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
  "."/[api_new_desc, api_legacy_desc, base_desc]

type
  CoreDbApiTrackRef* = CoreDbChldRefs | CoreDbRef
  CoreDxApiTrackRef* = CoreDxChldRefs | CoreDbRef

  CoreDbFnInx* = enum
    ## Profiling table index
    SummaryItem         = "total"

    AccDeleteFn         = "acc/delete"
    AccFetchFn          = "acc/fetch"
    AccForgetFn         = "acc/forget"
    AccGetTrieFn        = "acc/getTrie"
    AccHasPathFn        = "acc/hasPath"
    AccMergeFn          = "acc/merge"
    AccGetMptFn         = "acc/getMpt"
    AccPersistentFn     = "acc/persistent"
    AccStoFlushFn       = "acc/stoFlush"
    AccToMptFn          = "acc/toMpt"

    AnyBackendFn        = "any/backend"
    AnyIsPruningFn      = "any/isPruning"

    BaseDbTypeFn        = "dbType"
    BaseFinishFn        = "finish"
    BaseLegacySetupFn   = "compensateLegacySetup"
    BaseLevelFn         = "level"
    BaseNewCaptureFn    = "newCapture"
    BaseNewCtxFn        = "ctx"
    BaseNewCtxFromTxFn  = "ctxFromTx"
    BaseSwapCtxFn       = "swapCtx"
    BaseNewKvtFn        = "newKvt"
    BaseNewTxFn         = "newTransaction"

    CptFlagsFn          = "cpt/flags"
    CptLogDbFn          = "cpt/logDb"
    CptRecorderFn       = "cpt/recorder"
    CptForgetFn         = "cpt/forget"

    CtxForgetFn         = "ctx/forget"
    CtxGetAccFn         = "ctx/getAcc"
    CtxGetMptFn         = "ctx/getMpt"
    CtxNewTrieFn        = "ctx/newTrie"

    ErrorPrintFn        = "$$"
    EthAccRecastFn      = "recast"

    KvtDelFn            = "kvt/del"
    KvtForgetFn         = "kvt/forget"
    KvtGetFn            = "kvt/get"
    KvtGetOrEmptyFn     = "kvt/getOrEmpty"
    KvtHasKeyFn         = "kvt/hasKey"
    KvtPairsIt          = "kvt/pairs"
    KvtPersistentFn     = "kvt/persistent"
    KvtPutFn            = "kvt/put"

    LegaBeginTxFn       = "beginTransaction"
    LegaCaptureFn       = "capture"
    LegaCptFlagsFn      = "cpt/flags"
    LegaCptLogDbFn      = "cpt/logDb"
    LegaCptRecorderFn   = "cpt/recorder"
    LegaIsPruningFn     = "trie/isPruning"

    LegaKvtContainsFn   = "kvt/contains"
    LegaKvtDelFn        = "kvt/del"
    LegaKvtGetFn        = "kvt/get"
    LegaKvtPairsIt      = "kvt/pairs"
    LegaKvtPutFn        = "kvt/put"

    LegaMptContainsFn   = "mpt/contains"
    LegaMptDelFn        = "mpt/del"
    LegaMptGetFn        = "mpt/get"
    LegaMptPutFn        = "mpt/put"
    LegaMptRootHashFn   = "mpt/rootHash"
    LegaMptPairsIt      = "mpt/pairs"
    LegaMptReplicateIt  = "mpt/replicate"

    LegaNewKvtFn        = "kvt"
    LegaNewMptFn        = "mptPrune"
    LegaNewPhkFn        = "phkPrune"

    LegaPhkContainsFn   = "phk/contains"
    LegaPhkDelFn        = "phk/del"
    LegaPhkGetFn        = "phk/get"
    LegaPhkPutFn        = "phk/put"
    LegaPhkRootHashFn   = "phk/rootHash"

    LegaToMptFn         = "phk/toMpt"
    LegaToPhkFn         = "mpt/toPhk"

    LegaTxCommitFn      = "lega/commit"
    LegaTxDisposeFn     = "lega/dispose"
    LegaTxRollbackFn    = "lega/rollback"
    LegaTxSaveDisposeFn = "lega/safeDispose"

    MptDeleteFn         = "mpt/delete"
    MptFetchFn          = "mpt/fetch"
    MptFetchOrEmptyFn   = "mpt/fetchOrEmpty"
    MptForgetFn         = "mpt/forget"
    MptGetTrieFn        = "mpt/getTrie"
    MptHasPathFn        = "mpt/hasPath"
    MptMergeFn          = "mpt/merge"
    MptPairsIt          = "mpt/pairs"
    MptPersistentFn     = "mpt/persistent"
    MptReplicateIt      = "mpt/replicate"
    MptToPhkFn          = "mpt/toPhk"

    PhkDeleteFn         = "phk/delete"
    PhkFetchFn          = "phk/fetch"
    PhkFetchOrEmptyFn   = "phk/fetchOrEmpty"
    PhkForgetFn         = "phk/forget"
    PhkGetTrieFn        = "phk/getTrie"
    PhkHasPathFn        = "phk/hasPath"
    PhkMergeFn          = "phk/merge"
    PhkPersistentFn     = "pkk/persistent"
    PhkToMptFn          = "phk/toMpt"

    RootHashFn          = "rootHash"
    TriePrintFn         = "$$"

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

proc toStr*(p: CoreDbTrieRef): string =
  let
    w = if p.isNil or not p.ready: "nil" else: p.parent.methods.triePrintFn(p)
    (a,b) = if 0 < w.len and w[0] == '(': ("","") else: ("(",")")
  "Trie" & a & w & b

func toStr*(w: CoreDbKvtRef): string =
  if w.distinctBase.isNil: "kvt(nil)" else: "kvt"

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

proc toStr*(rc: CoreDbRc[CoreDbTrieRef]): string =
  if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[set[CoreDbCaptFlags]]): string =
  if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[Account]): string =
  if rc.isOk: "ok(Account)" else: "err(" & rc.error.toStr & ")"

proc toStr[T](rc: CoreDbRc[T]; ifOk: static[string]): string =
  if rc.isOk: "ok(" & ifOk & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[CoreDbRef]): string = rc.toStr "db"
proc toStr*(rc: CoreDbRc[CoreDbAccount]): string = rc.toStr "acc"
proc toStr*(rc: CoreDbRc[CoreDxKvtRef]): string = rc.toStr "kvt"
proc toStr*(rc: CoreDbRc[CoreDxTxRef]): string = rc.toStr "tx"
proc toStr*(rc: CoreDbRc[CoreDxCaptRef]): string = rc.toStr "capt"
proc toStr*(rc: CoreDbRc[CoreDbCtxRef]): string = rc.toStr "ctx"
proc toStr*(rc: CoreDbRc[CoreDxMptRef]): string = rc.toStr "mpt"
proc toStr*(rc: CoreDbRc[CoreDxAccRef]): string = rc.toStr "acc"

func toStr*(ela: Duration): string =
  aristo_profile.toStr(ela)

# ------------------------------------------------------------------------------
# Public legacy API logging framework
# ------------------------------------------------------------------------------

template beginLegaApi*(w: CoreDbApiTrackRef; s: static[CoreDbFnInx]) =
  when typeof(w) is CoreDbRef:
    let db = w
  else:
    let db = w.distinctBase.parent
  # Prevent from cascaded logging
  let save = db.trackNewApi
  db.trackNewApi = false
  defer: db.trackNewApi = save

  when CoreDbEnableApiProfiling:
    const blaCtx {.inject.} = s       # Local use only
  let blaStart {.inject.} = getTime() # Local use only

template endLegaApiIf*(w: CoreDbApiTrackRef; code: untyped) =
  block:
    when typeof(w) is CoreDbRef:
      let db = w
    else:
      let db = w.distinctBase.parent
    when CoreDbEnableApiProfiling:
      let elapsed {.inject,used.} = getTime() - blaStart
      aristo_profile.update(db.profTab, blaCtx.ord, elapsed)
    if db.trackLegaApi:
      when not CoreDbEnableApiProfiling: # otherwise use variable above
        let elapsed {.inject,used.} = getTime() - blaStart
      code

# ------------------------------------------------------------------------------
# Public new API logging framework
# ------------------------------------------------------------------------------

template beginNewApi*(w: CoreDxApiTrackRef; s: static[CoreDbFnInx]) =
  when CoreDbEnableApiProfiling:
    const bnaCtx {.inject.} = s       # Local use only
  let bnaStart {.inject.} = getTime() # Local use only

template endNewApiIf*(w: CoreDxApiTrackRef; code: untyped) =
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

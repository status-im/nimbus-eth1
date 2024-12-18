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
  std/[sequtils, strutils, times, typetraits],
  eth/common,
  results,
  stew/byteutils,
  ../../aristo/aristo_profile,
  "."/[base_config, base_desc]

type
  Elapsed* = distinct Duration
    ## Needed for local `$` as it would be ambiguous for `Duration`

  CoreDbApiTrackRef* =
    CoreDbRef | CoreDbKvtRef | CoreDbCtxRef | CoreDbAccRef |
    CoreDbTxRef

  CoreDbFnInx* = enum
    ## Profiling table index
    SummaryItem         = "total"

    AccClearStorageFn   = "clearStorage"
    AccDeleteFn         = "acc/delete"
    AccFetchFn          = "acc/fetch"
    AccHasPathFn        = "acc/hasPath"
    AccMergeFn          = "acc/merge"
    AccProofFn          = "acc/proof"
    AccRecastFn         = "recast"
    AccStateFn          = "acc/state"

    AccSlotFetchFn      = "slotFetch"
    AccSlotDeleteFn     = "slotDelete"
    AccSlotHasPathFn    = "slotHasPath"
    AccSlotMergeFn      = "slotMerge"
    AccSlotProofFn      = "slotProof"
    AccSlotStorageRootFn = "slotStorageRoot"
    AccSlotStorageEmptyFn = "slotStorageEmpty"
    AccSlotStorageEmptyOrVoidFn = "slotStorageEmptyOrVoid"
    AccSlotPairsIt      = "slotPairs"

    BaseFinishFn        = "finish"
    BaseLevelFn         = "level"
    BasePushCaptureFn   = "pushCapture"
    BaseNewTxFn         = "newTransaction"
    BasePersistentFn    = "persistent"
    BaseStateBlockNumberFn = "stateBlockNumber"
    BaseVerifyFn        = "verify"
    BaseVerifyOkFn      = "verifyOk"

    CptKvtLogFn         = "kvtLog"
    CptLevelFn          = "level"
    CptPopFn            = "pop"
    CptStopCaptureFn    = "stopCapture"

    CtxGetAccountsFn    = "getAccounts"
    CtxGetGenericFn     = "getGeneric"

    KvtDelFn            = "del"
    KvtGetFn            = "get"
    KvtGetOrEmptyFn     = "getOrEmpty"
    KvtHasKeyRcFn       = "hasKeyRc"
    KvtHasKeyFn         = "hasKey"
    KvtLenFn            = "len"
    KvtPairsIt          = "pairs"
    KvtPutFn            = "put"

    TxCommitFn          = "commit"
    TxDisposeFn         = "dispose"
    TxLevelFn           = "level"
    TxRollbackFn        = "rollback"
    TxSaveDisposeFn     = "safeDispose"

func toStr*(e: CoreDbError): string {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func oaToStr(w: openArray[byte]): string =
  w.toHex.toLowerAscii

# ------------------------------------------------------------------------------
# Public API logging helpers
# ------------------------------------------------------------------------------

func toStr(w: Hash32): string =
  if w == EMPTY_ROOT_HASH: "EMPTY_ROOT_HASH" else: w.data.oaToStr

func toStr(ela: Duration): string =
  aristo_profile.toStr(ela)

func toStr*(rc: CoreDbRc[int]|CoreDbRc[UInt256]): string =
  if rc.isOk: "ok(" & $rc.value & ")" else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[bool]): string =
  if rc.isOk: "ok(" & $rc.value & ")" else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[void]): string =
  if rc.isOk: "ok()" else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[seq[byte]]): string =
  if rc.isOk: "ok(seq[byte,#" & $rc.value.len & "])"
  else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[seq[seq[byte]]]): string =
  if rc.isOk: "ok([" & rc.value.mapIt("[#" & $it.len & "]").join(",") & "])"
  else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[(seq[seq[byte]],bool)]): string =
  if rc.isOk: "ok([" & rc.value[0].mapIt("[#" & $it.len & "]").join(",") &
                             "]," & $rc.value[1] & ")"
  else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[Hash32]): string =
  if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[Account]): string =
  if rc.isOk: "ok(Account)" else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[CoreDbAccount]): string =
  if rc.isOk: "ok(AristoAccount)" else: "err(" & rc.error.toStr & ")"

func toStr[T](rc: CoreDbRc[T]; ifOk: static[string]): string =
  if rc.isOk: "ok(" & ifOk & ")" else: "err(" & rc.error.toStr & ")"

func toStr(rc: CoreDbRc[CoreDbRef]): string = rc.toStr "db"
func toStr(rc: CoreDbRc[CoreDbKvtRef]): string = rc.toStr "kvt"
func toStr(rc: CoreDbRc[CoreDbTxRef]): string = rc.toStr "tx"
func toStr(rc: CoreDbRc[CoreDbCtxRef]): string = rc.toStr "ctx"
func toStr(rc: CoreDbRc[CoreDbAccRef]): string = rc.toStr "acc"

# ------------------------------------------------------------------------------
# Public API logging helpers
# ------------------------------------------------------------------------------

func toStr*(e: CoreDbError): string =
  result = $e.error & "("
  result &= (if e.isAristo: "Aristo" else: "Kvt")
  result &= ", ctx=" & $e.ctx & ", error="
  result &= (if e.isAristo: $e.aErr else: $e.kErr)
  result &= ")"

func toStr*(w: openArray[byte]): string =
  w.oaToStr

func toLenStr*(w: openArray[byte]): string =
  if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
  else: "openArray[" & $w.len & "]"

func `$`*[T](rc: CoreDbRc[T]): string = rc.toStr
func `$`*(t: Elapsed): string = t.Duration.toStr
func `$$`*(h: Hash32): string = h.toStr # otherwise collision w/existing `$`

# ------------------------------------------------------------------------------
# Public new API logging framework
# ------------------------------------------------------------------------------

template setTrackNewApi*(
    w: CoreDbApiTrackRef;
    s: static[CoreDbFnInx];
    code: untyped;
      ) =
  ## Template with code section that will be discarded if logging is
  ## disabled at compile time when `EnableApiTracking` is `false`.
  when CoreDbEnableApiTracking:
    #w.beginNewApi(s)
    when CoreDbEnableProfiling:
      const bnaCtx {.inject.} = s       # Local use only
    let bnaStart {.inject.} = getTime() # Local use only
    code
  const api {.inject,used.} = s

template setTrackNewApi*(
    w: CoreDbApiTrackRef;
    s: static[CoreDbFnInx];
      ) =
  w.setTrackNewApi(s):
    discard

template ifTrackNewApi*(w: CoreDbApiTrackRef; code: untyped) =
  when CoreDbEnableApiTracking:
    #w.endNewApiIf:
    #  code
    block body:
      when typeof(w) is CoreDbRef:
        let db = w
      elif typeof(w) is CoreDbTxRef:
        let db = w.ctx.parent
        if w.isNil: break body
      else:
        let db = w.distinctBase.parent
        if w.distinctBase.isNil: break body
      when CoreDbEnableProfiling:
        let elapsed {.inject,used.} = (getTime() - bnaStart).Elapsed
        aristo_profile.update(db.profTab, bnaCtx.ord, elapsed.Duration)
      if db.trackCoreDbApi:
        when not CoreDbEnableProfiling: # otherwise use variable above
          let elapsed {.inject,used.} = (getTime() - bnaStart).Elapsed
        code

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func init*(T: type CoreDbProfListRef): T =
  T(list: newSeq[CoreDbProfData](1 + high(CoreDbFnInx).ord))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

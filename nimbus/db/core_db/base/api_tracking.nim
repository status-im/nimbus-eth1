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
  std/[algorithm, math, sequtils, strformat, strutils, tables, times,
       typetraits],
  eth/common,
  results,
  stew/byteutils,
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
    AccHasPathFn        = "acc/hasPath"
    AccMergeFn          = "acc/merge"
    AccNewMptFn         = "acc/newMpt"
    AccPersistentFn     = "acc/persistent"
    AccRootVidFn        = "acc/toPhk"
    AccToMptFn          = "acc/toMpt"

    AnyBackendFn        = "any/backend"
    AnyIsPruningFn      = "any/isPruning"

    BaseCaptureFn       = "newCapture"
    BaseDbTypeFn        = "dbType"
    BaseFinishFn        = "finish"
    BaseGetRootFn       = "getRoot"
    BaseLegacySetupFn   = "compensateLegacySetup"
    BaseLevelFn         = "level"
    BaseNewAccFn        = "newAccMpt"
    BaseNewKvtFn        = "newKvt"
    BaseNewMptFn        = "newMpt"
    BaseNewTxFn         = "newTransaction"

    CptFlagsFn          = "cpt/flags"
    CptLogDbFn          = "cpt/logDb"
    CptRecorderFn       = "cpt/recorder"

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

    LegaBackendFn       = "trie/backend"
    LegaBeginTxFn       = "beginTransaction"
    LegaCaptureFn       = "capture"
    LegaCptFlagsFn      = "cpt/flags"
    LegaCptLogDbFn      = "cpt/logDb"
    LegaCptRecorderFn   = "cpt/recorder"
    LegaGetTxIdFn       = "getTransactionID"
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

    LegaShortTimeRoFn   = "shortTimeReadOnly"
    LegaToMptFn         = "phk/toMpt"
    LegaToPhkFn         = "mpt/toPhk"

    LegaTxCommitFn      = "tx/commit"
    LegaTxDisposeFn     = "tx/dispose"
    LegaTxLevelFn       = "tx/level"
    LegaTxRollbackFn    = "tx/rollback"
    LegaTxSaveDisposeFn = "tx/safeDispose"

    MptDeleteFn         = "mpt/delete"
    MptFetchFn          = "mpt/fetch"
    MptFetchOrEmptyFn   = "mpt/fetchOrEmpty"
    MptForgetFn         = "mpt/forget"
    MptHasPathFn        = "mpt/hasPath"
    MptMergeFn          = "mpt/merge"
    MptPairsIt          = "mpt/pairs"
    MptPersistentFn     = "mpt/persistent"
    MptReplicateIt      = "mpt/replicate"
    MptRootVidFn        = "mpt/rootVid"
    MptToPhkFn          = "mpt/toPhk"

    PhkDeleteFn         = "phk/delete"
    PhkFetchFn          = "phk/fetch"
    PhkFetchOrEmptyFn   = "phk/fetchOrEmpty"
    PhkForgetFn         = "phk/forget"
    PhkHasPathFn        = "phk/hasPath"
    PhkMergeFn          = "phk/merge"
    PhkPersistentFn     = "pkk/persistent"
    PhkRootVidFn        = "phk/toPhk"
    PhkToMptFn          = "phk/toMpt"

    TxCommitFn          = "tx/commit"
    TxDisposeFn         = "tx/dispose"
    TxLevelFn           = "tx/level"
    TxRollbackFn        = "tx/rollback"
    TxSaveDisposeFn     = "tx/safeDispose"

    VidHashFn           = "vid/hash"

  CoreDbProfFnInx* = array[CoreDbFnInx,(float,float,int)]
  CoreDbProfEla* = seq[(Duration,seq[CoreDbFnInx])]
  CoreDbProfMean* = seq[(Duration,seq[CoreDbFnInx])]
  CoreDbProfCount* = seq[(int,seq[CoreDbFnInx])]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toDuration(fl: float): Duration =
  ## Convert the nanoseconds argument `ns` to a `Duration`.
  let (s, ns) = fl.splitDecimal
  initDuration(seconds = s.int, nanoseconds = (ns * 1_000_000_000).int)

func toFloat(ela: Duration): float =
  ## Convert the argument `ela` to a floating point seconds result.
  let
    elaS = ela.inSeconds
    elaNs = (ela - initDuration(seconds=elaS)).inNanoSeconds
  elaS.float + elaNs.float / 1_000_000_000

proc updateTotal(t: var CoreDbProfFnInx; fnInx: CoreDbFnInx) =
  ## Summary update helper
  if fnInx == SummaryItem:
    t[SummaryItem] = (0.0, 0.0, 0)
  else:
    t[SummaryItem][0] += t[fnInx][0]
    t[SummaryItem][1] += t[fnInx][1]
    t[SummaryItem][2] += t[fnInx][2]

# -----------------

func oaToStr(w: openArray[byte]): string =
  w.toHex.toLowerAscii

proc toStr(e: CoreDbErrorRef): string =
  $e.error & "(" & e.parent.methods.errorPrintFn(e) & ")"

func ppUs(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
  result = $elapsed.inMicroseconds
  let ns = elapsed.inNanoseconds mod 1_000 # fraction of a micro second
  if ns != 0:
    # to rounded deca milli seconds
    let du = (ns + 5i64) div 10i64
    result &= &".{du:02}"
  result &= "us"

func ppMs(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
  result = $elapsed.inMilliseconds
  let ns = elapsed.inNanoseconds mod 1_000_000 # fraction of a milli second
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

func ppSecs(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000 # fraction of a second
  if ns != 0:
    # round up
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

func ppMins(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
  result = $elapsed.inMinutes
  let ns = elapsed.inNanoseconds mod 60_000_000_000 # fraction of a minute
  if ns != 0:
    # round up
    let dm = (ns + 500_000_000i64) div 1_000_000_000i64
    result &= &":{dm:02}"
  result &= "m"

# ------------------------------------------------------------------------------
# Public API logging helpers
# ------------------------------------------------------------------------------

func toStr*(w: Hash256): string =
  if w == EMPTY_ROOT_HASH: "EMPTY_ROOT_HASH" else: w.data.oaToStr

proc toStr*(p: CoreDbVidRef): string =
  if p.isNil:
    "vidRef(nil)"
  elif not p.ready:
    "vidRef(not-ready)"
  else:
    let val = p.parent.methods.tryHashFn(p).valueOr: EMPTY_ROOT_HASH
    if val != EMPTY_ROOT_HASH:
      "vidRef(some-hash)"
    else:
      "vidRef(empty-hash)"

func toStr*(w: CoreDbKvtRef): string =
  if w.distinctBase.isNil: "kvtRef(nil)" else: "kvtRef"

func toStr*(w: Blob): string =
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

proc toStr*(rc: CoreDbRc[Account]): string =
  if rc.isOk: "ok(Account)" else: "err(" & rc.error.toStr & ")"

proc toStr[T](rc: CoreDbRc[T]; ifOk: static[string]): string =
  if rc.isOk: "ok(" & ifOk & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[CoreDbRef]): string = rc.toStr "dbRef"
proc toStr*(rc: CoreDbRc[CoreDbVidRef]): string = rc.toStr "vidRef"
proc toStr*(rc: CoreDbRc[CoreDbAccount]): string = rc.toStr "accRef"
proc toStr*(rc: CoreDbRc[CoreDxTxID]): string = rc.toStr "txId"
proc toStr*(rc: CoreDbRc[CoreDxTxRef]): string = rc.toStr "txRef"
proc toStr*(rc: CoreDbRc[CoreDxCaptRef]): string = rc.toStr "captRef"
proc toStr*(rc: CoreDbRc[CoreDxMptRef]): string = rc.toStr "mptRef"
proc toStr*(rc: CoreDbRc[CoreDxAccRef]): string = rc.toStr "accRef"

func toStr*(elapsed: Duration): string =
  try:
    if 0 < times.inMinutes(elapsed):
      result = elapsed.ppMins
    elif 0 < times.inSeconds(elapsed):
      result = elapsed.ppSecs
    elif 0 < times.inMilliSeconds(elapsed):
      result = elapsed.ppMs
    elif 0 < times.inMicroSeconds(elapsed):
      result = elapsed.ppUs
    else:
      result = $elapsed.inNanoSeconds & "ns"
  except ValueError:
    result = $elapsed

# ------------------------------------------------------------------------------
# Public legacy API logging framework
# ------------------------------------------------------------------------------

template beginLegaApi*(w: CoreDbApiTrackRef) =
  when typeof(w) is CoreDbRef:
    let db = w
  else:
    let db = w.distinctBase.parent
  # Prevent from cascaded logging
  let save = db.trackNewApi
  db.trackNewApi = false
  defer: db.trackNewApi = save

  let blaStart {.inject.} = getTime()

template endLegaApiIf*(w: CoreDbApiTrackRef; code: untyped) =
  block:
    when typeof(w) is CoreDbRef:
      let db = w
    else:
      let db = w.distinctBase.parent
    if db.trackLegaApi:
      let elapsed {.inject,used.} = getTime() - blaStart
      code

# ------------------------------------------------------------------------------
# Public new API logging framework
# ------------------------------------------------------------------------------

template beginNewApi*(w: CoreDxApiTrackRef) =
  let bnaStart {.inject.} = getTime()

template endNewApiIf*(w: CoreDxApiTrackRef; code: untyped) =
  block:
    when typeof(w) is CoreDbRef:
      let db = w
    else:
      if w.isNil: break
      let db = w.parent
    if db.trackNewApi:
      let elapsed {.inject,used.} = getTime() - bnaStart
      code

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc update*(t: var CoreDbProfFnInx; fn: CoreDbFnInx; ela: Duration) =
  ## Register time `ela` spent while executing function `fn`
  let s = ela.toFloat
  t[fn][0] += s
  t[fn][1] += s * s
  t[fn][2].inc


proc byElapsed*(t: var CoreDbProfFnInx): CoreDbProfEla =
  ## Collate `CoreDb` function symbols by elapsed times, sorted with largest
  ## `Duration` first. Zero `Duration` entries are discarded.
  var u: Table[Duration,seq[CoreDbFnInx]]
  for fn in CoreDbFnInx:
    t.updateTotal fn
    let (secs,sqSum,count) = t[fn]
    if 0 < count:
      let ela = secs.toDuration
      u.withValue(ela,val):
         val[].add fn
      do:
        u[ela] = @[fn]
  result.add (t[SummaryItem][0].toDuration, @[SummaryItem])
  for ela in u.keys.toSeq.sorted Descending:
    u.withValue(ela,val):
      result.add (ela, val[])


proc byMean*(t: var CoreDbProfFnInx): CoreDbProfMean =
  ## Collate `CoreDb` function symbols by elapsed mean times, sorted with
  ## largest `Duration` first. Zero `Duration` entries are discarded.
  var u: Table[Duration,seq[CoreDbFnInx]]
  for fn in CoreDbFnInx:
    t.updateTotal fn
    let (secs,sqSum,count) = t[fn]
    if 0 < count:
      let ela = (secs / count.float).toDuration
      u.withValue(ela,val):
         val[].add fn
      do:
        u[ela] = @[fn]
  result.add (
    (t[SummaryItem][0] / t[SummaryItem][2].float).toDuration, @[SummaryItem])
  for mean in u.keys.toSeq.sorted Descending:
    u.withValue(mean,val):
      result.add (mean, val[])


proc byVisits*(t: var CoreDbProfFnInx): CoreDbProfCount =
  ## Collate  `CoreDb` function symbols by number of visits, sorted with
  ## largest number first.
  var u: Table[int,seq[CoreDbFnInx]]
  for fn in CoreDbFnInx:
    t.updateTotal fn
    let (secs,sqSum,count) = t[fn]
    if 0 < count:
      let ela = secs.toDuration
      u.withValue(count,val):
        val[].add fn
      do:
        u[count] = @[fn]
  result.add (t[SummaryItem][2], @[SummaryItem])
  for count in u.keys.toSeq.sorted Descending:
    u.withValue(count,val):
      result.add (count, val[])


proc stats*(
    t: CoreDbProfFnInx;
    fnInx: CoreDbFnInx;
      ): tuple[n: int, mean: Duration, stdDev: Duration, devRatio: float] =
  ## Print mean and strandard deviation of timing
  let data = t[fnInx]
  result.n = data[2]
  if 0 < result.n:
    let
      mean = data[0] / result.n.float
      sqMean = data[1] / result.n.float
      meanSq = mean * mean

      # Mathematically, `meanSq <= sqMean` but there might be rounding errors
      # if `meanSq` and `sqMean` are approximately the same.
      sigma = sqMean - min(meanSq,sqMean)
      stdDev = sigma.sqrt

    result.mean = mean.toDuration
    result.stdDev = stdDev.sqrt.toDuration

    if 0 < mean:
      result.devRatio = stdDev / mean

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

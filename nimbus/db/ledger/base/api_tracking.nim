# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, math, sequtils, strformat, strutils, tables, times],
  eth/common,
  stew/byteutils,
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
    LdgDeleteAccountFn         = "deleteAccount"
    LdgDisposeFn               = "dispose"
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
    LdgHasCodeOrNonceFn        = "hasCodeOrNonce"
    LdgInAccessListFn          = "inAccessList"
    LdgIncNonceFn              = "incNonce"
    LdgIsDeadAccountFn         = "isDeadAccount"
    LdgIsEmptyAccountFn        = "isEmptyAccount"
    LdgIsTopLevelCleanFn       = "isTopLevelClean"
    LdgLogEntriesFn            = "logEntries"
    LdgMakeMultiKeysFn         = "makeMultiKeys"
    LdgPersistFn               = "persist"
    LdgRipemdSpecialFn         = "ripemdSpecial"
    LdgRollbackFn              = "rollback"
    LdgRootHashFn              = "rootHash"
    LdgSafeDisposeFn           = "safeDispose"
    LdgSelfDestructFn          = "selfDestruct"
    LdgSelfDestruct6780Fn      = "selfDestruct6780"
    LdgSelfDestructLenFn       = "selfDestructLen"
    LdgSetBalanceFn            = "setBalance"
    LdgSetCodeFn               = "setCode"
    LdgSetNonceFn              = "setNonce"
    LdgSetStorageFn            = "setStorage"
    LdgSetTransientStorageFn   = "setTransientStorage"
    LdgSubBalanceFn            = "subBalance"
    LdgGetMptFn                = "getMpt"
    LdgRawRootHashFn           = "rawRootHash"

    LdgAccountsIt              = "accounts"
    LdgAdressesIt              = "addresses"
    LdgCachedStorageIt         = "cachedStorage"
    LdgPairsIt                 = "pairs"
    LdgStorageIt               = "storage"

  LedgerProfFnInx* = array[LedgerFnInx,(float,float,int)]
  LedgerProfEla* = seq[(Duration,seq[LedgerFnInx])]
  LedgerProfMean* = seq[(Duration,seq[LedgerFnInx])]
  LedgerProfCount* = seq[(int,seq[LedgerFnInx])]

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

proc updateTotal(t: var LedgerProfFnInx; fnInx: LedgerFnInx) =
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

func toStr*(w: EthAddress): string =
  w.oaToStr

func toStr*(w: Hash256): string =
  w.data.oaToStr

func toStr*(w: CoreDbMptRef): string =
  if w.CoreDxMptRef.isNil: "MptRef(nil)" else: "MptRef"

func toStr*(w: Blob): string =
  if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
  else: "Blob[" & $w.len & "]"

func toStr*(w: seq[Log]): string =
  "Logs[" & $w.len & "]"

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
# Public API logging framework
# ------------------------------------------------------------------------------

template beginApi*(ldg: LedgerRef) =
  let baStart {.inject.} = getTime()

template endApiIf*(ldg: LedgerRef; code: untyped) =
  if ldg.trackApi:
    let elapsed {.inject,used.} = getTime() - baStart
    code

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc update*(t: var LedgerProfFnInx; fn: LedgerFnInx; ela: Duration) =
  ## Register time `ela` spent while executing function `fn`
  let s = ela.toFloat
  t[fn][0] += s
  t[fn][1] += s * s
  t[fn][2].inc


proc byElapsed*(t: var LedgerProfFnInx): LedgerProfEla =
  ## Collate `Ledger` function symbols by elapsed times, sorted with largest
  ## `Duration` first. Zero `Duration` entries are discarded.
  var u: Table[Duration,seq[LedgerFnInx]]
  for fn in LedgerFnInx:
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


proc byMean*(t: var LedgerProfFnInx): LedgerProfMean =
  ## Collate `Ledger` function symbols by elapsed mean times, sorted with
  ## largest `Duration` first. Zero `Duration` entries are discarded.
  var u: Table[Duration,seq[LedgerFnInx]]
  for fn in LedgerFnInx:
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


proc byVisits*(t: var LedgerProfFnInx): LedgerProfCount =
  ## Collate  `Ledger` function symbols by number of visits, sorted with
  ## largest number first.
  var u: Table[int,seq[LedgerFnInx]]
  for fn in LedgerFnInx:
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
    t: LedgerProfFnInx;
    fnInx: LedgerFnInx;
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

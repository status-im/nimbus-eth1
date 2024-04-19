# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[algorithm, math, sequtils, strformat, strutils, tables, times],
  eth/common

type
  AristoDbProfData* = tuple[sum: float, sqSum: float, count: int, masked: bool]

  AristoDbProfListRef* = ref object of RootRef
    ## Statistic table synced with name indexes from `AristoDbProfNames`. Here
    ## a `ref` is used so it can be modified when part of another object.
    ##
    list*: seq[AristoDbProfData]

  AristoDbProfEla* = seq[(Duration,seq[uint])]
  AristoDbProfMean* = seq[(Duration,seq[uint])]
  AristoDbProfCount* = seq[(int,seq[uint])]
  AristoDbProfStats* = tuple
    count:    int
    total:    Duration
    mean:     Duration
    stdDev:   Duration
    devRatio: float
    masked:   bool

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

proc updateTotal(t: AristoDbProfListRef; fnInx: uint) =
  ## Summary update helper
  if fnInx == 0:
    t.list[0].sum = 0.0
    t.list[0].sqSum = 0.0
    t.list[0].count = 0
  elif t.list[0].masked == false:
    t.list[0].sum += t.list[fnInx].sum
    t.list[0].sqSum += t.list[fnInx].sqSum
    t.list[0].count += t.list[fnInx].count

# ---------------------

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
# Public helpers
# ------------------------------------------------------------------------------

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

proc update*(t: AristoDbProfListRef; inx: uint; ela: Duration) =
  ## Register time `ela` spent while executing function `fn`
  let s = ela.toFloat
  t.list[inx].sum += s
  t.list[inx].sqSum += s * s
  t.list[inx].count.inc


proc byElapsed*(t: AristoDbProfListRef): AristoDbProfEla =
  ## Collate `CoreDb` function symbols by elapsed times, sorted with largest
  ## `Duration` first. Zero `Duration` entries are discarded.
  var u: Table[Duration,seq[uint]]
  for inx in 0u ..< t.list.len.uint:
    t.updateTotal inx
    let (secs,_,count,_) = t.list[inx]
    if 0 < count:
      let ela = secs.toDuration
      u.withValue(ela,val):
         val[].add inx
      do:
        u[ela] = @[inx]
  result.add (t.list[0u].sum.toDuration, @[0u])
  for ela in u.keys.toSeq.sorted Descending:
    u.withValue(ela,val):
      result.add (ela, val[])


proc byMean*(t: AristoDbProfListRef): AristoDbProfMean =
  ## Collate `CoreDb` function symbols by elapsed mean times, sorted with
  ## largest `Duration` first. Zero `Duration` entries are discarded.
  var u: Table[Duration,seq[uint]]
  for inx in 0u ..< t.list.len.uint:
    t.updateTotal inx
    let (secs,_,count,_) = t.list[inx]
    if 0 < count:
      let ela = (secs / count.float).toDuration
      u.withValue(ela,val):
         val[].add inx
      do:
        u[ela] = @[inx]
  result.add ((t.list[0u].sum / t.list[0u].count.float).toDuration, @[0u])
  for mean in u.keys.toSeq.sorted Descending:
    u.withValue(mean,val):
      result.add (mean, val[])


proc byVisits*(t: AristoDbProfListRef): AristoDbProfCount =
  ## Collate  `CoreDb` function symbols by number of visits, sorted with
  ## largest number first.
  var u: Table[int,seq[uint]]
  for fnInx in 0 ..< t.list.len:
    t.updateTotal fnInx.uint
    let (_,_,count,_) = t.list[fnInx]
    if 0 < count:
      u.withValue(count,val):
        val[].add fnInx.uint
      do:
        u[count] = @[fnInx.uint]
  result.add (t.list[0u].count, @[0u])
  for count in u.keys.toSeq.sorted Descending:
    u.withValue(count,val):
      result.add (count, val[])


func stats*(
    t: AristoDbProfListRef;
    inx: uint;
      ): AristoDbProfStats =
  ## Print mean and strandard deviation of timing
  let data = t.list[inx]
  result.count = data.count
  result.masked = data.masked
  if 0 < result.count:
    let
      mean = data.sum / result.count.float
      sqMean = data.sqSum / result.count.float
      meanSq = mean * mean

      # Mathematically, `meanSq <= sqMean` but there might be rounding errors
      # if `meanSq` and `sqMean` are approximately the same.
      sigma = sqMean - min(meanSq,sqMean)
      stdDev = sigma.sqrt

    result.total = data.sum.toDuration
    result.mean = mean.toDuration
    result.stdDev = stdDev.sqrt.toDuration

    if 0 < mean:
      result.devRatio = stdDev / mean

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

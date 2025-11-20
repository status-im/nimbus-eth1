# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

## Extracted helpers from `worker_desc` (avoids circular import)

import
  std/math,
  pkg/[chronos, eth/common, stew/interval_set],
  ../../../core/chain,
  ../../../networking/p2p,
  ../../../utils/[prettify, utils],
  ../../sync_desc,
  ./worker_const

export
  prettify, short, `$`

type
  MeanVarStats* = tuple
    ## Statistics helper structure, time parameters in nano-seconds
    mean: float
    variance: float
    samples: uint
    total: uint64


func toStr*(w: (BlockNumber,BlockNumber)): string =
  if w[0] < w[1]: $w[0] & ".." & $w[1]
  elif w[0] == w[1]: $w[0]
  else: "n/a"

func toStr*(w: seq[EthBlock]): string =
  if w.len == 0: "n/a"
  else: (w[0].header.number, w[^1].header.number).toStr

func toStr*(rev: seq[Header]): string =
  ## Pretty print *reverse* sequence of headers as interval
  if rev.len == 0: "n/a" else: (rev[^1].number,rev[0].number).toStr

func toStr*(w: Interval[BlockNumber,uint64]): string =
  (w.minPt,w.maxPt).toStr


func toStr*(a: chronos.Duration): string =
  if twoHundredYears <= a:
    return "n/a"
  var s = a.toString 2
  if s.len == 0: s="0"
  s

func toStr*(w: MeanVarStats): string =
  ## Throughput per second
  if w.samples == 0:
    result = "n/a"
  else:
    let mean = w.mean.uint64
    result = mean.toIECb(1) & "ps"
    if 0 < w.variance:
      let stdDev = sqrt(w.variance).uint64
      # Ignore if `stdDev` is less than 5% of `mean`
      if mean <= 20 * stdDev:
        result &= "~" & stdDev.toIECb(1) & "ps"
    result &= "/" & w.total.toIEC(1) & ":" & $w.samples.toIEC(1)

func toStr*(h: Hash32): string =
  if h == emptyRoot: "n/a"
  elif h == zeroHash32: "n/a"
  else: h.short

func `$`*(w: Interval[BlockNumber,uint64]): string =
  w.toStr

func `$`*(w: (SyncState,HeaderChainMode,bool)): string =
  $w[0] & "." & $w[1] & (if w[2]: ":" & "poolMode" else: "")

func `$`*(w: (BuddyRunState,SyncState,HeaderChainMode,bool)): string =
  $w[0] & ":" & $(w[1],w[2],w[3])

# End

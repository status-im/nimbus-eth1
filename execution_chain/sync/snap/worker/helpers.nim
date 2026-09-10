# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  std/[fenv, hashes, math, strformat, strutils],
  pkg/[chronos, stew/interval_set],
  ../../../core/chain,
  ../../../networking/p2p,
  ../../../utils/[prettify, utils],
  ../../sync_desc,
  ./[extra_types, worker_const]

export
  prettify, short, `$`


func short*(peerID: Hash): string =
  let s = peerID.toHex
  s.substr(s.len-8).toLowerAscii

func toStr*(h: Hash32): string =
  if h == emptyRoot: "empty"
  elif h == zeroHash32: "zero"
  else: h.short

func toStr*(h: Opt[Hash32]): string =
  if h.isNone: "n/a" else: h.unsafeGet.toStr

func toStr*(w: DistinctHash32): string = w.Hash32.toStr

func toStr*(w: Opt[DistinctHash32]): string =
  if w.isNone: Opt.none(Hash32).toStr
  else: Opt.some(w.unsafeGet.Hash32).toStr

# --------------

func toStr*(w: float, precision: static[int] = 7): string =
  if w == 0f:
    "0.0"
  elif w == 1f:
    "1.0"
  else:
    when precision == 2:
      &"{w:.2e}"
    elif precision == 3:
      &"{w:.3e}"
    elif precision == 4:
      &"{w:.4e}"
    elif precision == 7:
      &"{w:.7e}"
    elif precision == 11:
      &"{w:.11e}"
    elif precision == 15:
      &"{w:.15e}"
    else:
      {.error: "Unsupported precision".}

func pcStr*(w: float): string =
  ## Shortcut for `toPC(6)`
  if w == 0f:
    "0.0"
  elif w == 1f:
    "1.0"
  else:
    w.toPC(6)

func toStr*(w: (float,float), precision: static[int] = 4): string =
  if w[0] < w[1]: w[0].toStr(precision) & ".." & w[1].toStr(precision)
  elif w[0] == w[1]: w[0].toStr(precision)
  else: "n/a"

func flStr*(w: UInt256, precision: static[int] = 4): string =
  if w == high(UInt256): "2^256-1"
  elif w.isZero: "0"
  else: w.to(float).toStr(precision)

func flStr*(w: (UInt256,UInt256), precision: static[int] = 4): string =
  if w[0].isZero:
    if w[1] == high(UInt256):
      "0..2^256-1"
    else:
      "0.." & w[1].to(float).toStr(precision)
  elif w[1] == high(UInt256):
    w[0].to(float).toStr(precision) & "..2^256-1"
  elif w[0] < w[1]:
    w[0].to(float).toStr(precision) & ".." & w[1].to(float).toStr(precision)
  elif w[0] == w[1]:
    w[0].to(float).toStr(precision)
  else:
    "n/a"

func flStr*(w: ItemKey): string =
  w.to(UInt256).flStr

func flStr*(w: (ItemKey,ItemKey)): string =
  (w[0].to(UInt256),w[1].to(UInt256)).flStr

func flStr*(w: ItemKeyRange): string =
  (w.minPt,w.maxPt).flStr

func flStr*(ikrs: ItemKeyRangeSet, maxIvs = 2): string =
  result = "{"
  var count = 0
  for iv in ikrs.increasing:
    if maxIvs <= count:
      break
    count.inc
    result &= iv.flStr & ","
  if count <= 0:
    result &= "}"
  elif count <= maxIvs:
    result[^1] = '}'
  else:
    result &= "..[" & $ikrs.chunks & "]..}"

func lenStr*(w: (UInt256,UInt256)): string =
  if w[0].isZero and w[1] == high(UInt256):
    "2^256"
  elif w[0] <= w[1]:
    let z = w[1] - w[0]
    if z < high(int).u256:
      $z
    else:
      z.to(float).toStr
  else:
    "?"

func lenStr*(w: (ItemKey,ItemKey)): string =
  (w[0].to(UInt256),w[1].to(UInt256)).lenStr

func lenStr*(w: ItemKeyRange): string =
  (w.minPt,w.maxPt).lenStr

# --------------

func toStr*(a: chronos.Duration): string =
  if twoHundredYears <= a:
    return "n/a"
  var s = a.toString 2
  if s.len == 0: s="0s"
  s

func toStr*(a: chronos.Moment): string =
  (a - low(Moment)).toStr

# -----------

func `$`*(w: (SnapState,bool)): string =
  $w[0] & (if w[1]: "+" & "poolMode" else: "")

func `$`*(w: (string,SyncPeerRunState,SnapState,bool)): string =
  if 0 < w[0].len:
    result = w[0] & "/"
  result &= $w[1] & ":" & $(w[2],w[3])

func `$`*(w: ItemKey|ItemKeyRange): string =
  w.flStr

# End

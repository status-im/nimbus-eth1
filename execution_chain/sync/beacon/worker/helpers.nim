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
  pkg/[chronos, eth/common, results, stew/interval_set],
  ../../../core/chain,
  ../../../networking/p2p,
  ../../../utils/[prettify, utils],
  ../../sync_desc,
  ../worker_const

export
  prettify, short, `$`

func bnStr*(w: BlockNumber): string =
  "#" & $w

func bnStr*(h: Header): string =
  h.number.bnStr

func bnStr*(b: EthBlock): string =
  b.header.bnStr

func bnStr*(w: (BlockNumber,BlockNumber)): string =
  if w[0] < w[1]: w[0].bnStr & ".." & w[1].bnStr
  elif w[0] == w[1]: w[0].bnStr
  else: "n/a"

func bnStr*(w: seq[EthBlock]): string =
  if w.len == 0: "n/a"
  else: (w[0].header.number, w[^1].header.number).bnStr

func bnStr*(rev: seq[Header]): string =
  ## Pretty print *reverse* sequence of headers as interval
  if rev.len == 0: "n/a" else: (rev[^1].number,rev[0].number).bnStr

func bnStr*(w: Interval[BlockNumber,uint64]): string =
  (w.minPt,w.maxPt).bnStr


func toStr*(a: chronos.Duration): string =
  var s = a.toString 2
  if s.len == 0: s="0"
  s

func toStr*(h: Hash32): string =
  if h == emptyRoot: "n/a"
  elif h == zeroHash32: "n/a"
  else: h.short


func `$`*(w: Interval[BlockNumber,uint64]): string =
  w.bnStr

func `$`*(w: Opt[Peer]): string =
  if w.isSome: $w.value else: "n/a"

func `$`*(w: (SyncState,HeaderChainMode,bool)): string =
  $w[0] & "." & $w[1] & (if w[2]: ":" & "poolMode" else: "")

func `$`*(w: (BuddyRunState,SyncState,HeaderChainMode,bool)): string =
  $w[0] & ":" & $(w[1],w[2],w[3])

# End

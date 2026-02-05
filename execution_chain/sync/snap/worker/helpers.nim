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
  std/strformat,
  pkg/[chronos, stew/interval_set],
  ../../../core/chain,
  ../../../networking/p2p,
  ../../../utils/[prettify, utils],
  ../../sync_desc,
  ./worker_const

export
  prettify, short, `$`


func toStr*(h: Hash32): string =
  if h == emptyRoot: "n/a"
  elif h == zeroHash32: "n/a"
  else: h.short

func toStr*(w: float): string =
  &"{w:.7g}" # => 1.234567e+x

func toStr*(w: (float,float)): string =
  if w[0] < w[1]: w[0].toStr & ".." & w[1].toStr
  elif w[0] == w[1]: w[0].toStr
  else: "n/a"


func toStr*(a: chronos.Duration): string =
  if twoHundredYears <= a:
    return "n/a"
  var s = a.toString 2
  if s.len == 0: s="0"
  s

# -----------

func `$`*(w: (SyncState,bool)): string =
  $w[0] & (if w[1]: "+" & "poolMode" else: "")

func `$`*(w: (string,SyncPeerRunState,SyncState,bool)): string =
  if 0 < w[0].len:
    result = w[0] & "/"
  result &= $w[1] & ":" & $(w[2],w[3])

# End

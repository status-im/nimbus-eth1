# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
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
  pkg/chronos,
  pkg/eth/common,
  pkg/stew/interval_set

func bnStr*(w: BlockNumber): string =
  "#" & $w

func bnStr*(h: Header): string =
  h.number.bnStr

func bnStr*(b: EthBlock): string =
  b.header.bnStr

func bnStr*(w: Interval[BlockNumber,uint64]): string =
  if w.len == 1: w.minPt.bnStr else: w.minPt.bnStr & ".." & w.maxPt.bnStr

func toStr*(a: chronos.Duration): string =
  a.toString 2


proc `$`*(w: Interval[BlockNumber,uint64]): string =
  w.bnStr

# End

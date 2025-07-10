# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/[sequtils, strutils],
  pkg/[chronicles, chronos],
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../../worker_desc

# ------------------------------------------------------------------------------
# Public logging functions
# ------------------------------------------------------------------------------

func bnStr*(w: BnRangeSet): string =
  "{" & w.increasing.toSeq.mapIt(it.bnStr).join(",") & "}"

func bnStr*(w: StagedBlocksQueue): string =
  result = "{"
  var rc = w.ge(0)
  while rc.isOk:
    result &= rc.value.data.blocks.bnStr & ","
    rc = w.gt(rc.value.key)
  if result[^1] == ',':
     result[^1] = '}'
  else:
    result &= "}"

func bnStr*(w: BlocksFetchSync): string =
  "(" & w.unprocessed.bnStr &
    "," & w.borrowed.bnStr &
    "," & w.staged.bnStr &
    ")"

proc verify*(blk: BlocksFetchSync): bool =
  # Unprocessed intervals must not overlap
  for iv in blk.borrowed.increasing:
    if 0 < blk.unprocessed.covered(iv):
      trace "verify: borrowed and unprocessed overlap", blk=blk.bnStr
      return false
  # Check stashed against unprocessed intervals
  var rc = blk.staged.ge(0)
  while rc.isOk:
    let
      minPt = rc.value.data.blocks[0].header.number
      maxPt = rc.value.data.blocks[^1].header.number
    if 0 < blk.unprocessed.covered(minPt, maxPt):
      trace "verify: staged and unprocessed overlap", blk=blk.bnStr
      return false
    if 0 < blk.borrowed.covered(minPt, maxPt):
      trace "verify: staged and borrowed overlap", blk=blk.bnStr
      return false
    rc = blk.staged.gt(rc.value.key)
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

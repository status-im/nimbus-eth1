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
# Private logging helpers
# ------------------------------------------------------------------------------

func bnStr(w: seq[Header]): string =
  ## Pretty print reverse sequence of headers as interval
  if w.len == 0: "n/a" else: (w[^1].number,w[0].number).bnStr

# ------------------------------------------------------------------------------
# Public logging functions
# ------------------------------------------------------------------------------

func bnStr*(w: BnRangeSet): string =
  "{" & w.increasing.toSeq.mapIt(it.bnStr).join(",") & "}"

func bnStr*(w: StagedHeaderQueue): string =
  result = "{"
  var rc = w.ge(0)
  while rc.isOk:
    result &= rc.value.data.revHdrs.bnStr & ","
    rc = w.gt(rc.value.key)
  if result[^1] == ',':
     result[^1] = '}'
  else:
    result &= "}"

func bnStr*(w: HeaderFetchSync): string =
  "(" & w.unprocessed.bnStr &
    "," & w.borrowed.bnStr &
    "," & w.staged.bnStr &
    ")"

proc verify*(hdr: HeaderFetchSync): bool =
  # Unprocessed intervals must not overlap
  for iv in hdr.borrowed.increasing:
    if 0 < hdr.unprocessed.covered(iv):
      trace "verify: borrowed and unprocessed overlap", hdr=hdr.bnStr
      return false
  # Check stashed against unprocessed intervals
  var rc = hdr.staged.ge(0)
  while rc.isOk:
    let
      minPt = rc.value.data.revHdrs[^1].number
      maxPt = rc.value.data.revHdrs[0].number
    if 0 < hdr.unprocessed.covered(minPt, maxPt):
      trace "verify: staged and unprocessed overlap", hdr=hdr.bnStr
      return false
    if 0 < hdr.borrowed.covered(minPt, maxPt):
      trace "verify: staged and borrowed overlap", hdr=hdr.bnStr
      return false
    rc = hdr.staged.gt(rc.value.key)
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

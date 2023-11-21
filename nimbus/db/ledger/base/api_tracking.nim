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
  std/[strformat, strutils, times],
  eth/common,
  stew/byteutils,
  ../../core_db,
  "."/base_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func oaToStr(w: openArray[byte]): string =
  w.toHex.toLowerAscii

func ppUs*(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
  result = $elapsed.inMicroseconds
  let ns = elapsed.inNanoseconds mod 1_000 # fraction of a micro second
  if ns != 0:
    # to rounded deca milli seconds
    let du = (ns + 5i64) div 10i64
    result &= &".{du:02}"
  result &= "us"

func ppMs*(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
  result = $elapsed.inMilliseconds
  let ns = elapsed.inNanoseconds mod 1_000_000 # fraction of a milli second
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

func ppSecs*(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000 # fraction of a second
  if ns != 0:
    # round up
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

func ppMins*(elapsed: Duration): string {.gcsafe, raises: [ValueError].} =
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
    let elapsed {.inject.} = getTime() - baStart
    code

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strformat, strutils, times, typetraits],
  eth/common,
  results,
  stew/byteutils,
  "."/[api_new_desc, api_legacy_desc, base_desc]

type
  CoreDbApiTrackRef* = CoreDbChldRefs | CoreDbRef
  CoreDxApiTrackRef* = CoreDxChldRefs | CoreDbRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func oaToStr(w: openArray[byte]): string =
  w.toHex.toLowerAscii

proc toStr(e: CoreDbErrorRef): string =
  $e.error & "(" & e.parent.methods.errorPrintFn(e) & ")"

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

func toStr*(w: Hash256): string =
  if w == EMPTY_ROOT_HASH: "EMPTY_ROOT_HASH" else: w.data.oaToStr

proc toStr*(p: CoreDbVidRef): string =
  if p.isNil:
    "vidRef(nil)"
  elif not p.ready:
    "vidRef(not-ready)"
  else:
    let val = p.parent.methods.vidHashFn(p,false).valueOr: EMPTY_ROOT_HASH
    if val != EMPTY_ROOT_HASH:
      "vidRef(some-hash)"
    else:
      "vidRef(empty-hash)"

func toStr*(w: CoreDbKvtRef): string =
  if w.distinctBase.isNil: "kvtRef(nil)" else: "kvtRef"

func toStr*(w: Blob): string =
  if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
  else: "Blob[" & $w.len & "]"

func toStr*(w: openArray[byte]): string =
  w.oaToStr

func toStr*(w: set[CoreDbCaptFlags]): string =
  "Flags[" & $w.len & "]"

proc toStr*(rc: CoreDbRc[bool]): string =
  if rc.isOk: "ok(" & $rc.value & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[void]): string =
  if rc.isOk: "ok()" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[Blob]): string =
  if rc.isOk: "ok(Blob[" & $rc.value.len & "])"
  else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[Hash256]): string =
  if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[Account]): string =
  if rc.isOk: "ok(Account)" else: "err(" & rc.error.toStr & ")"

proc toStr[T](rc: CoreDbRc[T]; ifOk: static[string]): string =
  if rc.isOk: "ok(" & ifOk & ")" else: "err(" & rc.error.toStr & ")"

proc toStr*(rc: CoreDbRc[CoreDbRef]): string = rc.toStr "dbRef"
proc toStr*(rc: CoreDbRc[CoreDbVidRef]): string = rc.toStr "vidRef"
proc toStr*(rc: CoreDbRc[CoreDbAccount]): string = rc.toStr "accRef"
proc toStr*(rc: CoreDbRc[CoreDxTxID]): string = rc.toStr "txId"
proc toStr*(rc: CoreDbRc[CoreDxTxRef]): string = rc.toStr "txRef"
proc toStr*(rc: CoreDbRc[CoreDxCaptRef]): string = rc.toStr "captRef"

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
# Public legacy API logging framework
# ------------------------------------------------------------------------------

template legaApiCtx*(w: CoreDbApiTrackRef; ctx: static[string]): string =
  var txt = ctx
  when w is CoreDbKvtRef: txt = "kvt" & "/" & ctx
  when w is CoreDbPhkRef: txt = "phk" & "/" & ctx
  when w is CoreDbMptRef: txt = "mpt" & "/" & ctx
  when w is CoreDbTxRef:  txt = "tx" & "/" & ctx
  txt

template beginLegaApi*(w: CoreDbApiTrackRef) =
  when typeof(w) is CoreDbRef:
    let db = w
  else:
    let db = w.distinctBase.parent
  # Prevent from cascaded logging
  let save = db.trackNewApi
  db.trackNewApi = false
  defer: db.trackNewApi = save

  let blaStart {.inject.} = getTime()

template endLegaApiIf*(w: CoreDbApiTrackRef; code: untyped) =
  block:
    when typeof(w) is CoreDbRef:
      let db = w
    else:
      let db = w.distinctBase.parent
    if db.trackLegaApi:
      let elapsed {.inject,used.} = getTime() - blaStart
      code

# ------------------------------------------------------------------------------
# Public new API logging framework
# ------------------------------------------------------------------------------

template newApiCtx*(w: CoreDxApiTrackRef; ctx: static[string]): string =
  var txt = ctx
  when w is CoreDxKvtRef: txt = "kvt" & "/" & ctx
  when w is CoreDxPhkRef: txt = "phk" & "/" & ctx
  when w is CoreDxAccRef: txt = "acc" & "/" & ctx
  when w is CoreDxMptRef: txt = "mpt" & "/" & ctx
  when w is CoreDxTxRef: txt = "tx" & "/" & ctx
  txt

template beginNewApi*(w: CoreDxApiTrackRef) =
  let bnaStart {.inject.} = getTime()

template endNewApiIf*(w: CoreDxApiTrackRef; code: untyped) =
  block:
    when typeof(w) is CoreDbRef:
      let db = w
    else:
      if w.isNil: break
      let db = w.parent
    if db.trackNewApi:
      let elapsed {.inject,used.} = getTime() - bnaStart
      code

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

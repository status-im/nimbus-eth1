# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Pretty printing, an alternative to `$` for debugging
## ----------------------------------------------------
##
## minimal dependencies, avoiding circular import

import
  std/[sequtils, strformat, strutils, tables, times],
  eth/common,
  stew/byteutils,
  ../../nimbus/constants

export sequtils, strformat, strutils

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

func reGroup(q: openArray[int], itemsPerSegment = 16): seq[seq[int]] =
  var top = 0
  while top < q.len:
    let w = top
    top = min(w + itemsPerSegment, q.len)
    result.add q[w ..< top]

# ------------------------------------------------------------------------------
# Public functions, units pretty printer
# ------------------------------------------------------------------------------

func ppUs*(elapsed: Duration): string =
  result = $elapsed.inMicroseconds
  let ns = elapsed.inNanoseconds mod 1_000 # fraction of a micro second
  if ns != 0:
    # to rounded deca milli seconds
    let du = (ns + 5i64) div 10i64
    result &= &".{du:02}"
  result &= "us"

func ppMs*(elapsed: Duration): string =
  result = $elapsed.inMilliseconds
  let ns = elapsed.inNanoseconds mod 1_000_000 # fraction of a milli second
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

func ppSecs*(elapsed: Duration): string =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000 # fraction of a second
  if ns != 0:
    # round up
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

func ppMins*(elapsed: Duration): string =
  result = $elapsed.inMinutes
  let ns = elapsed.inNanoseconds mod 60_000_000_000 # fraction of a minute
  if ns != 0:
    # round up
    let dm = (ns + 500_000_000i64) div 1_000_000_000i64
    result &= &":{dm:02}"
  result &= "m"

func toKMG*[T](s: T): string =
  func subst(s: var string, tag, new: string): bool =
    if tag.len < s.len and s[s.len - tag.len ..< s.len] == tag:
      s = s[0 ..< s.len - tag.len] & new
      return true
  result = $s
  for w in [
    ("000", "K"),
    ("000K", "M"),
    ("000M", "G"),
    ("000G", "T"),
    ("000T", "P"),
    ("000P", "E"),
    ("000E", "Z"),
    ("000Z", "Y"),
  ]:
    if not result.subst(w[0], w[1]):
      return

func pp*(elapsed: Duration): string =
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
# Public functions,  pretty printer
# ------------------------------------------------------------------------------

func pp*(s: string, hex = false): string =
  if hex:
    let n = (s.len + 1) div 2
    (if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len - 8 .. s.len - 1]) & "[" &
      (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    s
  else:
    (if (s.len and 1) == 0: s[0 ..< 8] else: "0" & s[0 ..< 7]) & "..(" & $s.len & ").." &
      s[s.len - 16 ..< s.len]

func pp*(q: openArray[int], itemsPerLine: int, lineSep: string): string =
  doAssert q == q.reGroup(itemsPerLine).concat

  q.reGroup(itemsPerLine).mapIt(it.mapIt(&"0x{it:02x}").join(", ")).join("," & lineSep)

func pp*(a: MDigest[256], collapse = true): string =
  if not collapse:
    a.data.toHex
  elif a == ZERO_HASH256:
    "ZERO_HASH256"
  elif a == EMPTY_ROOT_HASH:
    "EMPTY_ROOT_HASH"
  elif a == EMPTY_UNCLE_HASH:
    "EMPTY_UNCLE_HASH"
  elif a == EMPTY_SHA3:
    "EMPTY_SHA3"
  elif a == ZERO_HASH256:
    "ZERO_HASH256"
  else:
    "£" & a.data.toHex.join[0 .. 6] & ".." & a.data.toHex.join[56 .. 63]

func pp*(a: openArray[MDigest[256]], collapse = true): string =
  "@[" & a.toSeq.mapIt(it.pp).join(" ") & "]"

func pp*(q: openArray[int], itemsPerLine: int, indent: int): string =
  q.pp(itemsPerLine = itemsPerLine, lineSep = "\n" & " ".repeat(max(1, indent)))

func pp*(q: openArray[byte], noHash = false): string =
  if q.len == 32 and not noHash:
    var a: array[32, byte]
    for n in 0 .. 31:
      a[n] = q[n]
    MDigest[256](data: a).pp
  else:
    q.toHex.pp(hex = true)

# ------------------------------------------------------------------------------
# Elapsed time pretty printer
# ------------------------------------------------------------------------------

template showElapsed*(noisy: bool, info: string, code: untyped) =
  block:
    let seStartTrackling = getTime()
    block:
      code
    if noisy:
      let elpd {.inject.} = getTime() - seStartTrackling
      if 0 < times.inSeconds(elpd):
        echo "*** ", info, &": {elpd.ppSecs:>4}"
      else:
        echo "*** ", info, &": {elpd.ppMs:>4}"

template showElapsed*(noisy: bool, info: string, elapsed: Duration, code: untyped) =
  block:
    let seStartTrackling = getTime()
    block:
      code
    block:
      elapsed = getTime() - seStartTrackling
      if noisy:
        let elpd {.inject.} = elapsed
        if 0 < times.inSeconds(elpd):
          echo "*** ", info, &": {elpd.ppSecs:>4}"
        else:
          echo "*** ", info, &": {elpd.ppMs:>4}"

template profileSection*(
    noisy: bool, info: string, state: var (Duration, int), suspend: bool, code: untyped
) =
  block:
    let psStartProfiling = getTime()
    block:
      code
    if not suspend:
      let elpd = getTime() - psStartProfiling
      if noisy:
        echo "*** ", info, ": ", elpd.pp
      state[0] += elpd
      state[1].inc

template profileSection*(
    noisy: bool, info: string, state: var (Duration, int), code: untyped
) =
  noisy.profileSection(info, state, suspend = false):
    code

template catchException*(info: string, trace: bool, code: untyped) =
  block:
    try:
      code
    except CatchableError as e:
      if trace:
        echo "*** ", info, ": exception ", e.name, "(", e.msg, ")"
        echo "    ", e.getStackTrace.strip.replace("\n", "\n    ")

template catchException*(info: string, code: untyped) =
  catchException(info, false, code)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

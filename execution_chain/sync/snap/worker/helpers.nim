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
  std/[fenv, math, strformat],
  pkg/[chronos, stew/interval_set],
  ../../../core/chain,
  ../../../networking/p2p,
  ../../../utils/[prettify, utils],
  ../../sync_desc,
  ./worker_const

export
  prettify, short, `$`


func toStr*(h: Hash32): string =
  if h == emptyRoot: "empty"
  elif h == zeroHash32: "zero"
  else: h.short

# --------------

func to*(w: UInt256; _: type float): float =
  ## Lossy conversion to `float`
  ##
  when sizeof(float) != sizeof(uint):
    {.error: "Expected float having the same size as uint".}
  let mantissa = 256 - w.leadingZeros
  if mantissa <= mantissaDigits(float):             # `<= 53` on a 64 bit system
    return w.truncate(uint).float
  # Calculate `w / 2^exp * 2^exp` = `w`
  let exp = mantissa - mantissaDigits(float)        # is positive
  (w shr exp).truncate(uint).float * 2f.pow(exp.float)


func per256*(w: UInt256): float =
  ## Represents the quotiont `w / 2^256` as `float` value. Note that the
  ## result is non-negaive and always smaller than `1f`.
  ##
  when sizeof(float) != sizeof(uint):
    {.error: "Expected float having the same size as uint".}
  if w == 0:
    return 0f
  let mantissa = 256 - w.leadingZeros
  if mantissa <= mantissaDigits(float):             # `<= 53` on a 64 bit system
    return w.truncate(uint).float / 2f.pow(256.float)
  # Calculate `total / 2^exp / 2^(256-exp)` = `total / 2^256`
  let exp = mantissa - mantissaDigits(float)        # is positive
  (w shr exp).truncate(uint).float / 2f.pow((256 - exp).float)

func per256*(w: Opt[UInt256]): float =
  ## Variant of `per256()` where the argument `w` covers the full scalar
  ## range with `Opt.none()` repesenting `0` and `Opt.some(0)` representing
  ## `2^255` (where the latter is not in the scalar range for `UInt256`,
  ## anymore.)
  ##
  if w.isNone: 0f
  elif w.value == 0: 1f
  else: w.value.per256()


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

func toStr*(w: (float,float), precision: static[int] = 4): string =
  if w[0] < w[1]: w[0].toStr(precision) & ".." & w[1].toStr(precision)
  elif w[0] == w[1]: w[0].toStr(precision)
  else: "n/a"

func flStr*(w: UInt256): string =
  if w == high(UInt256): "2^256"
  elif w == 0: "0"
  else: w.to(float).toStr

func flStr*(w: (UInt256,UInt256)): string =
  if w[0] != 0:
    (w[0].to(float),w[1].to(float)).toStr
  elif w[1] != high(UInt256):
    "0.." & w[1].flStr
  else:
    "0..2^256"

# --------------

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

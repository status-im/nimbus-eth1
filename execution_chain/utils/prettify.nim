# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Some logging helper moved here in absence of a known better place.

{.push raises: [].}

import
  std/[math, strformat]

proc dotFormat(w: float; digitsAfterDot: static[int]): string =
  when digitsAfterDot == 0:
    let rnd = if 0f < w: 0.5 else: -0.5
    $(w + rnd).int64
  elif digitsAfterDot == 1:
    &"{w:.1f}"
  elif digitsAfterDot == 2:
    &"{w:.2f}"
  elif digitsAfterDot == 3:
    &"{w:.3f}"
  elif digitsAfterDot == 4:
    &"{w:.3f}"
  else:
    {.error: "unsupported digitsAfterDot setting".}

proc unitFormat(
    num: SomeInteger;
    denom: static[float];
    uFirst: static[string];
    units: static[seq[char]];
    digitsAfterDot: static[int];
      ): string =
  ## Prints `num` argument value greater than 99 as rounded SI unit.
  const denomUint = denom.uint
  if num < denomUint:
    when uFirst.len == 0:
      return $num
    else:
      return $num & uFirst
  var w = num.float
  for u in units:
    w /= denom
    if w < denom:
      return w.dotFormat(digitsAfterDot) & $u
  when digitsAfterDot == 0:
    w.dotFormat(0) & $units[^1]
  else:
    w.dotFormat(1) & $units[^1]

# -----------

proc toPC*(num: float; digitsAfterDot: static[int] = 2): string =
  ## Convert argument number `num` to percent string with decimal precision
  ## given as `digitsAfterDot`.
  (num * 100f).dotFormat(digitsAfterDot) & "%"

proc toSI*(num: SomeUnsignedInt; digitsAfterDot: static[int] = 2): string =
  ## Prints `num` argument as rounded SI unit.
  unitFormat(num, 1000f, "", @['k', 'm', 'g' , 't', 'p', 'e'], digitsAfterDot)

proc toSI*(num: SomeInteger; digitsAfterDot: static[int] = 2): string =
  ## Ditto for possibly negative integers.
  var (pfx, sign) = if 0 <= num: ("", 1) else: ("-", -1)
  pfx & (sign * num).uint64.toSI(digitsAfterDot)

proc toIEC*(num: SomeUnsignedInt; digitsAfterDot: static[int] = 2): string =
  ## K=KiB, M=MiB, G=GiB, etc. (sort of standrdised by IEC).
  unitFormat(num, 1024f, "", @['K', 'M', 'G' , 'T', 'P', 'E'], digitsAfterDot)

proc toIECb*(num: SomeUnsignedInt; digitsAfterDot: static[int] = 2): string =
  ## Similar to `toIEC()` but with the unit `B` for `num` values smaller
  ## than 1024. This is useful for throughput pretty printing as in
  ## `toIECb() & "ps"`
  unitFormat(num, 1024f, "B", @['K', 'M', 'G' , 'T', 'P', 'E'], digitsAfterDot)

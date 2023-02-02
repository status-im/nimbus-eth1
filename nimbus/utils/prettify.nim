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

import
  std/[math, strutils]

{.push raises: [].}

proc toSI*(num: SomeUnsignedInt): string =
  ## Prints `num` argument value greater than 99 as rounded SI unit.
  const
    siUnits = [
      #                   <limit>                 <multiplier>   <symbol>
      (                   100_000u64,                     1000f64, 'k'),
      (               100_000_000u64,                 1000_000f64, 'm'),
      (           100_000_000_000u64,             1000_000_000f64, 'g'),
      (       100_000_000_000_000u64,         1000_000_000_000f64, 't'),
      (   100_000_000_000_000_000u64,     1000_000_000_000_000f64, 'p'),
      (10_000_000_000_000_000_000u64, 1000_000_000_000_000_000f64, 'e')]

    lastUnit =
      #           <no-limit-here>                 <multiplier>   <symbol>
      (                           1000_000_000_000_000_000_000f64, 'z')

  if num < 1000:
    return $num

  block checkRange:
    let
      uNum = num.uint64
      fRnd = (num.float + 5) * 100
    for (top, base, sig) in siUnits:
      if uNum < top:
        result = (fRnd / base).int.intToStr(3) & $sig
        break checkRange
    result = (fRnd / lastUnit[0]).int.intToStr(3) & $lastUnit[1]

  result.insert(".", result.len - 3)

proc toPC*(
    num: float;
    digitsAfterDot: static[int] = 2;
    rounding: static[float] = 5.0
      ): string =
  ## Convert argument number `num` to percent string with decimal precision
  ## stated as argument `digitsAfterDot`. Standard rounding is enabled by
  ## default adjusting the first invisible digit, set `rounding = 0` to disable.
  const
    minDigits = digitsAfterDot + 1
    multiplier = (10 ^ (minDigits + 1)).float
    roundUp = rounding / 10.0
  let
    sign = if num < 0: "-" else: ""
    preTruncated = (num.abs * multiplier) + roundUp

  if int.high.float <= preTruncated:
    return "NaN"
  # `intToStr` will do `abs` which throws overflow exception when value of low()
  if preTruncated.int <= int.low():
    return "NaN"

  result = sign & preTruncated.int.intToStr(minDigits) & "%"
  when 0 < digitsAfterDot:
    result.insert(".", result.len - minDigits)

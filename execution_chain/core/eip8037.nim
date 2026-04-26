# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  eth/common/base,
  stew/bitops2,
  intops/ops/[sub, add, mul, division]

const
  STATE_BYTES_PER_NEW_ACCOUNT* = 112
  STATE_BYTES_PER_AUTH_BASE* = 23
  REGULAR_PER_AUTH_BASE_COST* = 7500
  STATE_BYTES_PER_STORAGE_SET* = 32

  COST_NUMERATOR_MULTIPLIER = 2_628_000'u64
  TARGET_STATE_GROWTH_PER_YEAR = 100 * 1024 * 1024 * 1024
  COST_DENOMINATOR = 2 * TARGET_STATE_GROWTH_PER_YEAR
  CPSB_SIGNIFICANT_BITS = 5
  CPSB_OFFSET = 9578'u64

func calculateRaw(hi, lo: uint64): uint64 =
  # ulong raw = (ulong)((numerator + CostDenominator - 1) / CostDenominator);
  var
    hi = hi
    (num, carry) = overflowingAdd(lo, COST_DENOMINATOR)
  if carry: inc(hi)
  let (lo, c) = overflowingSub(num, 1)
  if c: dec(hi)
  let (q, _) = narrowingDiv(hi, lo, COST_DENOMINATOR)
  q

func stateGasPerByte*(gasLimit: GasInt): GasInt =
  let
    (num_hi, num_lo) = wideningMul(gasLimit, COST_NUMERATOR_MULTIPLIER)
    raw = calculateRaw(num_hi, num_lo)
    shifted = raw + CPSB_OFFSET
    shift = max(64 - leadingZeros(shifted) - CPSB_SIGNIFICANT_BITS, 0)
    rounded = (shifted shr shift) shl shift
    quantized = if rounded > CPSB_OFFSET: rounded - CPSB_OFFSET else: 0

  max(quantized, 1)

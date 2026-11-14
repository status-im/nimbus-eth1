# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  stint

from eth/common/base import GasInt

const
  BASE_FEE_MAX_CHANGE_DENOMINATOR = ##\
    ## Bounds the amount the base fee can change between blocks.
    8

  BASE_FEE_REFERENCE_SLOT_SECONDS = ##\
    ## Slot duration, in seconds, at which the base fee changes by at most
    ## `1 / BASE_FEE_MAX_CHANGE_DENOMINATOR` per block
    12

  ELASTICITY_MULTIPLIER = ##\
    ## Bounds the maximum gas limit an EIP-1559 block may have.
    2

proc calcEip8198BaseFee*(parentGasLimit, parentGasUsed: GasInt;
                         parentBaseFee: UInt256,
                         secondsElapsed: uint64,
                         slotsElapsed: uint64): UInt256 =
  ## calculates the basefee of the header.

  let parentGasTarget = parentGasLimit div ELASTICITY_MULTIPLIER

  # If the parent gasUsed is the same as the target, the baseFee remains
  # unchanged.
  if parentGasUsed == parentGasTarget:
    return parentBaseFee

  if slotsElapsed == 0:
    # prevent division by zero
    return 0.u256

  let
    slotsElapsed256 = slotsElapsed.u256
    baseFeeMaxChangeDenominator =
      (BASE_FEE_MAX_CHANGE_DENOMINATOR *
      BASE_FEE_REFERENCE_SLOT_SECONDS).u256 *
      slotsElapsed256
    secondsElapsed = min(secondsElapsed.u256,
      BASE_FEE_REFERENCE_SLOT_SECONDS.u256 * slotsElapsed256)

  if parentGasTarget < parentGasUsed:
    # If the parent block used more gas than its target, the baseFee should
    # increase.
    let
      gasUsedDelta = (parentGasUsed - parentGasTarget).u256
      targetFeeDelta = (parentBaseFee * gasUsedDelta) div parentGasTarget.u256
      baseFeeDelta = targetFeeDelta * secondsElapsed div baseFeeMaxChangeDenominator
    return parentBaseFee + max(baseFeeDelta, 1.u256)

  else:
    # Otherwise if the parent block used less gas than its target, the
    # baseFee should decrease.
    let
      gasUsedDelta = (parentGasTarget - parentGasUsed).u256
      targetFeeDelta = (parentBaseFee * gasUsedDelta) div parentGasTarget.u256
      baseFeeDelta = targetFeeDelta * secondsElapsed div baseFeeMaxChangeDenominator
    return max(parentBaseFee - baseFeeDelta, 0.u256)

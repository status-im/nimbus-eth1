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
  BASE_FEE_MAX_CHANGE_NUMERATOR = ##\
    ## Numerator of the largest fraction by which the base fee can change from one
    ## block to the next, used with [`BASE_FEE_MAX_CHANGE_DENOMINATOR`].
    5

  BASE_FEE_CHANGE_DENOMINATOR = ##\
    ## Bounds the amount the base fee can change between blocks.
    48

  ELASTICITY_MULTIPLIER = ##\
    ## Bounds the maximum gas limit an EIP-1559 block may have.
    2

proc calcEip8198BaseFee*(parentGasLimit, parentGasUsed: GasInt;
                         parentBaseFee: UInt256): UInt256 =
  ## calculates the basefee of the header.

  let parentGasTarget = parentGasLimit div ELASTICITY_MULTIPLIER

  # If the parent gasUsed is the same as the target, the baseFee remains
  # unchanged.
  if parentGasUsed == parentGasTarget:
    return parentBaseFee

  let parentGasDenom = parentGasTarget.u256 *
                         BASE_FEE_CHANGE_DENOMINATOR.u256

  if parentGasTarget < parentGasUsed:
    # If the parent block used more gas than its target, the baseFee should
    # increase.
    let
      gasUsedDelta = (parentGasUsed - parentGasTarget).u256
      baseFeeDelta = (parentBaseFee * gasUsedDelta * BASE_FEE_MAX_CHANGE_NUMERATOR) div parentGasDenom

    return parentBaseFee + max(baseFeeDelta, 1.u256)

  else:
    # Otherwise if the parent block used less gas than its target, the
    # baseFee should decrease.
    let
      gasUsedDelta = (parentGasTarget - parentGasUsed).u256
      baseFeeDelta = (parentBaseFee * gasUsedDelta * BASE_FEE_MAX_CHANGE_NUMERATOR) div parentGasDenom

    return max(parentBaseFee - baseFeeDelta, 0.u256)

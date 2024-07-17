# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Block Chain Helper: Gas Limits
## ==============================
##

import
  ../../../common/common,
  ../../../constants,
  ../../pow/header,
  eth/[eip1559]

{.push raises: [].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc gasLimitsGet*(com: CommonRef;
                   parent: BlockHeader): GasInt =

  if com.isLondonOrLater(parent.number+1):
    var parentGasLimit = parent.gasLimit
    if not com.isLondonOrLater(parent.number):
      # Bump by 2x
      parentGasLimit = parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
    calcGasLimit1559(parentGasLimit, desiredLimit = DEFAULT_GAS_LIMIT)
  else:
    computeGasLimit(
      parent.gasUsed,
      parent.gasLimit,
      gasFloor = DEFAULT_GAS_LIMIT,
      gasCeil = DEFAULT_GAS_LIMIT)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

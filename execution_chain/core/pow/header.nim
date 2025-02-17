# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

from ./difficulty import GAS_LIMIT_ADJUSTMENT_FACTOR, GAS_LIMIT_MINIMUM, GasInt

# CalcGasLimit1559 calculates the next block gas limit under 1559 rules.
func calcGasLimit1559*(parentGasLimit, desiredLimit: GasInt): GasInt =
  let delta = parentGasLimit div GAS_LIMIT_ADJUSTMENT_FACTOR - 1.GasInt
  var limit = parentGasLimit
  var desiredLimit = desiredLimit

  if desiredLimit < GAS_LIMIT_MINIMUM:
    desiredLimit = GAS_LIMIT_MINIMUM

  # If we're outside our allowed gas range, we try to hone towards them
  if limit < desiredLimit:
    limit = parentGasLimit + delta
    if limit > desiredLimit:
      limit = desiredLimit
    return limit

  if limit > desiredLimit:
    limit = parentGasLimit - delta
    if limit < desiredLimit:
      limit = desiredLimit

  limit

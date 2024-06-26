# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Block Chain Helper: Calculate Base Fee
## =======================================
##

import
  ../../../common/common,
  ../../../constants,
  eth/eip1559

{.push raises: [].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc baseFeeGet*(com: CommonRef;
                 parent: BlockHeader, timestamp: EthTime): Opt[UInt256] =
  ## Calculates the `baseFee` of the head assuming this is the parent of a
  ## new block header to generate.

  # Note that the baseFee is calculated for the next header
  if not com.isLondonOrLater(parent.number+1, timestamp):
    return Opt.none(UInt256)

  # If the new block is the first EIP-1559 block, return initial base fee.
  if not com.isLondonOrLater(parent.number, timestamp):
    return Opt.some(EIP1559_INITIAL_BASE_FEE)

  Opt.some calcEip1599BaseFee(
    parent.gasLimit,
    parent.gasUsed,
    parent.baseFeePerGas.get(0.u256))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  ../tx_item,
  eth/eip1559

{.push raises: [Defect].}

const
  INITIAL_BASE_FEE = EIP1559_INITIAL_BASE_FEE.truncate(uint64)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc baseFeeGet*(com: CommonRef; parent: BlockHeader): GasPrice =
  ## Calculates the `baseFee` of the head assuming this is the parent of a
  ## new block header to generate. This function is derived from
  ## `p2p/gaslimit.calcEip1599BaseFee()` which in turn has its origins on
  ## `consensus/misc/eip1559.go` of geth.

  # Note that the baseFee is calculated for the next header
  let
    forkDeterminer = forkDeterminationInfoForHeader(parent)
    parentFork = com.toEVMFork(forkDeterminer)
    nextFork = com.toEVMFork(forkDeterminer.adjustForNextBlock)

  if nextFork < FkLondon:
    return 0.GasPrice

  # If the new block is the first EIP-1559 block, return initial base fee.
  if parentFork < FkLondon:
    return INITIAL_BASE_FEE.GasPrice

  # TODO: which one is better?
  # truncate parent.baseFee to uint64 first and do the operation in uint64
  # or truncate the result?
  calcEip1599BaseFee(parent.gasLimit,
    parent.gasUsed,
    parent.baseFee).truncate(uint64).GasPrice

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

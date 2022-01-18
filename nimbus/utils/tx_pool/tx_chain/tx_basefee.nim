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
  ../../../chain_config,
  ../../../constants,
  ../../../forks,
  ../tx_item,
  eth/[common]

{.push raises: [Defect].}

const
  EIP1559_BASE_FEE_CHANGE_DENOMINATOR = ##\
    ## Bounds the amount the base fee can change between blocks.
    8

  EIP1559_ELASTICITY_MULTIPLIER = ##\
    ## Bounds the maximum gas limit an EIP-1559 block may have.
    2

  EIP1559_INITIAL_BASE_FEE = ##\
    ## Initial base fee for Eip1559 blocks.
    1_000_000_000

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc baseFeeGet*(config: ChainConfig; parent: BlockHeader): GasPrice =
  ## Calculates the `baseFee` of the head assuming this is the parent of a
  ## new block header to generate. This function is derived from
  ## `p2p/gaslimit.calcEip1599BaseFee()` which in turn has its origins on
  ## `consensus/misc/eip1559.go` of geth.

  # Note that the baseFee is calculated for the next header
  let
    parentGasUsed = parent.gasUsed
    parentGasLimit = parent.gasLimit
    parentBaseFee = parent.baseFee.truncate(uint64)
    parentFork = config.toFork(parent.blockNumber)
    nextFork = config.toFork(parent.blockNumber + 1)

  if nextFork < FkLondon:
    return 0.GasPrice

  # If the new block is the first EIP-1559 block, return initial base fee.
  if parentFork < FkLondon:
    return EIP1559_INITIAL_BASE_FEE.GasPrice

  let
    parGasTrg = parentGasLimit div EIP1559_ELASTICITY_MULTIPLIER
    parGasDenom = (parGasTrg * EIP1559_BASE_FEE_CHANGE_DENOMINATOR).uint64

  # If parent gasUsed is the same as the target, the baseFee remains unchanged.
  if parentGasUsed == parGasTrg:
    return parentBaseFee.GasPrice

  if parGasTrg < parentGasUsed:
    # If the parent block used more gas than its target, the baseFee should
    # increase.
    let
      gasUsedDelta = (parentGasUsed - parGasTrg).uint64
      baseFeeDelta = (parentBaseFee * gasUsedDelta) div parGasDenom

    return (parentBaseFee + max(1u64, baseFeeDelta)).GasPrice

  # Otherwise if the parent block used less gas than its target, the
  # baseFee should decrease.
  let
    gasUsedDelta = (parGasTrg - parentGasUsed).uint64
    baseFeeDelta = (parentBaseFee * gasUsedDelta) div parGasDenom

  if baseFeeDelta < parentBaseFee:
    return (parentBaseFee - baseFeeDelta).GasPrice

  0.GasPrice

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

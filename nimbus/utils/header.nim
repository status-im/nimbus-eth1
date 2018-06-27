# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.


import eth_common, ../constants, strformat, times, ../validation, rlp

export BlockHeader

proc hasUncles*(header: BlockHeader): bool = header.ommersHash != EMPTY_UNCLE_HASH

proc `$`*(header: BlockHeader): string =
  result = &"BlockHeader(timestamp: {header.timestamp} difficulty: {header.difficulty} blockNumber: {header.blockNumber} gasLimit: {header.gasLimit})"

proc gasLimitBounds*(parent: BlockHeader): (GasInt, GasInt) =
  ## Compute the boundaries for the block gas limit based on the parent block.
  let
    boundaryRange = parent.gasLimit div GAS_LIMIT_ADJUSTMENT_FACTOR
    upperBound = parent.gasLimit + boundaryRange
    lowerBound = max(GAS_LIMIT_MINIMUM, parent.gasLimit - boundaryRange)
  return (lowerBound, upperBound)

#[
proc validate_gaslimit(header: BlockHeader):
  let parent_header = getBlockHeaderByHash(header.parent_hash)
  low_bound, high_bound = compute_gas_limit_bounds(parent_header)
  if header.gas_limit < low_bound:
      raise ValidationError(
          "The gas limit on block {0} is too low: {1}. It must be at least {2}".format(
              encode_hex(header.hash), header.gas_limit, low_bound))
  elif header.gas_limit > high_bound:
      raise ValidationError(
          "The gas limit on block {0} is too high: {1}. It must be at most {2}".format(
              encode_hex(header.hash), header.gas_limit, high_bound))
]#

proc computeGasLimit*(parent: BlockHeader, gasLimitFloor: GasInt): GasInt =
  #[
    For each block:
    - decrease by 1/1024th of the gas limit from the previous block
    - increase by 50% of the total gas used by the previous block
    If the value is less than the given `gas_limit_floor`:
    - increase the gas limit by 1/1024th of the gas limit from the previous block.
    If the value is less than the GAS_LIMIT_MINIMUM:
    - use the GAS_LIMIT_MINIMUM as the new gas limit.
  ]#
  if gasLimitFloor < GAS_LIMIT_MINIMUM:
      raise newException(ValueError,
          &"""
          The `gasLimitFloor` value must be greater than the GAS_LIMIT_MINIMUM.
          Got {gasLimitFloor}. Must be greater than {GAS_LIMIT_MINIMUM}
          """
      )

  let decay = parent.gasLimit div GAS_LIMIT_EMA_DENOMINATOR
  var usageIncrease: GasInt

  if parent.gasUsed > 0:
      usageIncrease = (
          parent.gas_used * GAS_LIMIT_USAGE_ADJUSTMENT_NUMERATOR
      ) div GAS_LIMIT_USAGE_ADJUSTMENT_DENOMINATOR div GAS_LIMIT_EMA_DENOMINATOR

  let gasLimit = max(
      GAS_LIMIT_MINIMUM,
      parent.gasLimit - decay + usage_increase
  )

  if gas_limit < GAS_LIMIT_MINIMUM:
      return GAS_LIMIT_MINIMUM
  elif gas_limit < gasLimitFloor:
      return parent.gas_limit + decay
  else:
      return gas_limit

proc generateHeaderFromParentHeader*(
    computeDifficultyFn: proc(parentHeader: BlockHeader, timestamp: int): int,
    parent: BlockHeader,
    coinbase: EthAddress,
    timestamp: int = -1,
    extraData: string = ""): BlockHeader =
  # TODO: validateGt(timestamp, parent.timestamp)
  result = BlockHeader(
    timestamp: max(getTime(), parent.timestamp + 1.milliseconds),   # Note: Py-evm uses +1 second, not ms
    blockNumber: (parent.blockNumber + 1),
    # TODO: difficulty: parent.computeDifficulty(parent.timestamp),
    gasLimit: computeGasLimit(parent, gasLimitFloor = GENESIS_GAS_LIMIT),
    stateRoot: parent.stateRoot,
    coinbase: coinbase,
    # TODO: data: extraData,
  )

import nimcrypto
# TODO: required otherwise
# eth_common/rlp_serialization.nim(18, 12) template/generic instantiation from here
# nimcrypto/hash.nim(46, 6) Error: attempting to call undeclared routine: 'init'
proc hash*(b: BlockHeader): Hash256 {.inline.} = rlpHash(b)

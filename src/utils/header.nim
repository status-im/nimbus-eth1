# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.


import ../constants, ttmath, strformat, times, ../validation

type
  Header* = ref object
    timestamp*: EthTime
    difficulty*: UInt256
    blockNumber*: UInt256
    hash*: string
    unclesHash*: string
    coinbase*: string
    stateRoot*: string

  # TODO

proc hasUncles*(header: Header): bool = header.uncles_hash != EMPTY_UNCLE_HASH

proc gasUsed*(header: Header): UInt256 =
  # TODO
  # Should this be calculated/a proc? Parity and Py-Evm just have it as a field.
  0.u256

proc gasLimit*(header: Header): UInt256 =
  # TODO
  0.u256

proc `$`*(header: Header): string =
  if header.isNil:
    result = "nil"
  else:
    result = &"Header(timestamp: {header.timestamp} difficulty: {header.difficulty} blockNumber: {header.blockNumber} gasLimit: {header.gasLimit})"

proc gasLimitBounds*(parent: Header): (UInt256, UInt256) =
  ## Compute the boundaries for the block gas limit based on the parent block.
  let
    boundary_range = parent.gasLimit div GAS_LIMIT_ADJUSTMENT_FACTOR
    upper_bound = parent.gas_limit + boundary_range
    lower_bound = max(GAS_LIMIT_MINIMUM, parent.gas_limit - boundary_range)
  return (lower_bound, upper_bound)

#[
proc validate_gaslimit(header: Header):
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

proc computeGasLimit*(parent: Header, gasLimitFloor: UInt256): UInt256 =
  #[
    For each block:
    - decrease by 1/1024th of the gas limit from the previous block
    - increase by 50% of the total gas used by the previous block
    If the value is less than the given `gas_limit_floor`:
    - increase the gas limit by 1/1024th of the gas limit from the previous block.
    If the value is less than the GAS_LIMIT_MINIMUM:
    - use the GAS_LIMIT_MINIMUM as the new gas limit.
  ]#
  if gas_limit_floor < GAS_LIMIT_MINIMUM:
      raise newException(ValueError,
          &"""
          The `gas_limit_floor` value must be greater than the GAS_LIMIT_MINIMUM.
          Got {gasLimitFloor}. Must be greater than {GAS_LIMIT_MINIMUM}
          """
      )

  let decay = parent.gasLimit div GAS_LIMIT_EMA_DENOMINATOR
  var usageIncrease = u256(0)

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
  elif gas_limit < gas_limit_floor:
      return parent.gas_limit + decay
  else:
      return gas_limit

proc generateHeaderFromParentHeader*(
    computeDifficultyFn: proc(parentHeader: Header, timestamp: int): int,
    parent: Header,
    coinbase: string,
    timestamp: int = -1,
    extraData: string = ""): Header =
  # TODO: validateGt(timestamp, parent.timestamp)
  result = Header(
    timestamp: max(getTime(), parent.timestamp + 1.milliseconds),   # Note: Py-evm uses +1 second, not ms
    block_number: (parent.block_number + u256(1)),
    # TODO: difficulty: parent.computeDifficulty(parent.timestamp),
    #[TODO: Make field? Or do we need to keep as a proc?
    gas_limit: computeGasLimit(
      parent,
      gas_limit_floor=GENESIS_GAS_LIMIT,
    ),]#
    hash: parent.hash,
    state_root: parent.state_root,
    coinbase: coinbase,
    # TODO: data: extraData,
  )

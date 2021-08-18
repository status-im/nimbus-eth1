# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.


import
  strformat, times, options,
  eth/[common, rlp],
  ./difficulty, ../constants,
  ../chain_config

export BlockHeader

proc hasUncles*(header: BlockHeader): bool = header.ommersHash != EMPTY_UNCLE_HASH

proc `$`*(header: BlockHeader): string =
  result = &"BlockHeader(timestamp: {header.timestamp} difficulty: {header.difficulty} blockNumber: {header.blockNumber} gasLimit: {header.gasLimit})"

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
      parent.gasLimit - decay + usageIncrease
  )

  if gasLimit < GAS_LIMIT_MINIMUM:
    return GAS_LIMIT_MINIMUM
  elif gasLimit < gasLimitFloor:
    return parent.gasLimit + decay
  else:
    return gasLimit

proc generateHeaderFromParentHeader*(config: ChainConfig, parent: BlockHeader,
    coinbase: EthAddress, timestamp: Option[EthTime],
    gasLimit: Option[GasInt], extraData: Blob, baseFee: Option[Uint256]): BlockHeader =

  var lcTimestamp: EthTime
  if timestamp.isNone:
    lcTimeStamp = max(getTime(), parent.timestamp + 1.milliseconds)  # Note: Py-evm uses +1 second, not ms
  else:
    lcTimestamp = timestamp.get()

  if lcTimestamp <= parent.timestamp:
    raise newException(ValueError, "header.timestamp should be higher than parent.timestamp")

  result = BlockHeader(
    timestamp: lcTimestamp,
    blockNumber: (parent.blockNumber + 1),
    difficulty: config.calcDifficulty(lcTimestamp, parent),
    gasLimit: if gasLimit.isSome: gasLimit.get() else: computeGasLimit(parent, gasLimitFloor = GENESIS_GAS_LIMIT),
    stateRoot: parent.stateRoot,
    coinbase: coinbase,
    extraData: extraData,
    fee: baseFee
  )

# CalcGasLimit1559 calculates the next block gas limit under 1559 rules.
func calcGasLimit1559*(parentGasLimit, desiredLimit: GasInt): GasInt =
  let delta = parentGasLimit div GAS_LIMIT_EMA_DENOMINATOR - 1.GasInt
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

  return limit

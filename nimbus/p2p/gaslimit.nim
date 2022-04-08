# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strformat,
  stew/results,
  eth/common,
  ../db/db_chain,
  ../constants,
  ../chain_config,
  ../forks

const
  EIP1559_BASE_FEE_CHANGE_DENOMINATOR* = ##\
    ## Bounds the amount the base fee can change between blocks.
    8

  EIP1559_ELASTICITY_MULTIPLIER* = ##\
    ## Bounds the maximum gas limit an EIP-1559 block may have.
    2

  EIP1559_INITIAL_BASE_FEE* = ##\
    ## Initial base fee for Eip1559 blocks.
    1000000000.u256

# ------------------------------------------------------------------------------
# Pre Eip 1559 gas limit validation
# ------------------------------------------------------------------------------

proc validateGasLimit(header: BlockHeader; limit: GasInt): Result[void, string]
                     {.raises: [Defect].} =
  let diff = if limit > header.gasLimit:
               limit - header.gasLimit
             else:
               header.gasLimit - limit

  let upperLimit = limit div GAS_LIMIT_ADJUSTMENT_FACTOR

  if diff >= upperLimit:
    try:
      return err(&"invalid gas limit: have {header.gasLimit}, want {limit} +-= {upperLimit-1}")
    except ValueError:
      # TODO deprecate-strformat
      raiseAssert "strformat cannot fail"
  if header.gasLimit < GAS_LIMIT_MINIMUM:
    return err("invalid gas limit below 5000")
  ok()

proc validateGasLimit(c: BaseChainDB; header: BlockHeader): Result[void, string]
                     {.raises: [Defect].} =
  let parent = try:
    c.getBlockHeader(header.parentHash)
  except CatchableError:
    return err "Parent block not in database"
  header.validateGasLimit(parent.gasLimit)

# ------------------------------------------------------------------------------
# Eip 1559 support
# ------------------------------------------------------------------------------

# params/config.go(450): func (c *ChainConfig) IsLondon(num [..]
proc isLondonOrLater*(c: ChainConfig; number: BlockNumber): bool =
  c.toFork(number) >= FkLondon

# consensus/misc/eip1559.go(55): func CalcBaseFee(config [..]
proc calcEip1599BaseFee*(c: ChainConfig; parent: BlockHeader): UInt256 =
  ## calculates the basefee of the header.

  # If the current block is the first EIP-1559 block, return the
  # initial base fee.
  if not c.isLondonOrLater(parent.blockNumber):
    return EIP1559_INITIAL_BASE_FEE

  let parentGasTarget = parent.gasLimit div EIP1559_ELASTICITY_MULTIPLIER

  # If the parent gasUsed is the same as the target, the baseFee remains
  # unchanged.
  if parent.gasUsed == parentGasTarget:
    return parent.baseFee

  let parentGasDenom = parentGasTarget.u256 *
                         EIP1559_BASE_FEE_CHANGE_DENOMINATOR.u256

  # baseFee is an Option[T]
  let parentBaseFee  = parent.baseFee

  if parentGasTarget < parent.gasUsed:
    # If the parent block used more gas than its target, the baseFee should
    # increase.
    let
      gasUsedDelta = (parent.gasUsed - parentGasTarget).u256
      baseFeeDelta = (parentBaseFee * gasUsedDelta) div parentGasDenom

    return parentBaseFee + max(baseFeeDelta, 1.u256)

  else:
    # Otherwise if the parent block used less gas than its target, the
    # baseFee should decrease.
    let
      gasUsedDelta = (parentGasTarget - parent.gasUsed).u256
      baseFeeDelta = (parentBaseFee * gasUsedDelta) div parentGasDenom

    return max(parentBaseFee - baseFeeDelta, 0.u256)


# consensus/misc/eip1559.go(32): func VerifyEip1559Header(config [..]
proc verifyEip1559Header(c: ChainConfig;
                         parent, header: BlockHeader): Result[void, string]
                        {.raises: [Defect].} =
  ## Verify that the gas limit remains within allowed bounds
  let limit = if c.isLondonOrLater(parent.blockNumber):
                parent.gasLimit
              else:
                parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
  let rc = header.validateGasLimit(limit)
  if rc.isErr:
    return rc

  let headerBaseFee = header.baseFee
  # Verify the header is not malformed
  if headerBaseFee.isZero:
    return err("Post EIP-1559 header expected to have base fee")

  # Verify the baseFee is correct based on the parent header.
  var expectedBaseFee = c.calcEip1599BaseFee(parent)
  if headerBaseFee != expectedBaseFee:
    try:
      return err(&"invalid baseFee: have {expectedBaseFee}, "&
                 &"want {header.baseFee}, " &
                 &"parent.baseFee {parent.baseFee}, "&
                 &"parent.gasUsed {parent.gasUsed}")
    except ValueError:
      # TODO deprecate-strformat
      raiseAssert "strformat cannot fail"

  return ok()

proc validateGasLimitOrBaseFee*(c: BaseChainDB;
                                header, parent: BlockHeader): Result[void, string]
                               {.gcsafe, raises: [Defect].} =

  if not c.config.isLondonOrLater(header.blockNumber):
    # Verify BaseFee not present before EIP-1559 fork.
    if not header.baseFee.isZero:
      return err("invalid baseFee before London fork: have " & $header.baseFee & ", want <0>")
    let rc = c.validateGasLimit(header)
    if rc.isErr:
      return rc
  else:
    let rc = c.config.verifyEip1559Header(parent = parent,
                                          header = header)
    if rc.isErr:
      return rc

  return ok()

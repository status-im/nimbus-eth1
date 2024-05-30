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
  ../common/common,
  std/strformat,
  results,
  eth/[eip1559]

export
  eip1559

{.push raises: [].}

# ------------------------------------------------------------------------------
# Pre Eip 1559 gas limit validation
# ------------------------------------------------------------------------------

proc validateGasLimit(header: BlockHeader; limit: GasInt): Result[void,string] =
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

proc validateGasLimit(com: CommonRef; header: BlockHeader): Result[void, string] =
  let parent = try:
    com.db.getBlockHeader(header.parentHash)
  except CatchableError:
    return err "Parent block not in database"
  header.validateGasLimit(parent.gasLimit)

# ------------------------------------------------------------------------------
# Eip 1559 support
# ------------------------------------------------------------------------------

# consensus/misc/eip1559.go(55): func CalcBaseFee(config [..]
proc calcEip1599BaseFee*(com: CommonRef; parent: BlockHeader): UInt256 =
  ## calculates the basefee of the header.

  # If the current block is the first EIP-1559 block, return the
  # initial base fee.
  if com.isLondon(parent.blockNumber):
    eip1559.calcEip1599BaseFee(parent.gasLimit, parent.gasUsed, parent.baseFee)
  else:
    EIP1559_INITIAL_BASE_FEE

# consensus/misc/eip1559.go(32): func VerifyEip1559Header(config [..]
proc verifyEip1559Header(com: CommonRef;
                         parent, header: BlockHeader): Result[void, string]
                        {.raises: [].} =
  ## Verify that the gas limit remains within allowed bounds
  let limit = if com.isLondon(parent.blockNumber):
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
  var expectedBaseFee = com.calcEip1599BaseFee(parent)
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

proc validateGasLimitOrBaseFee*(com: CommonRef;
                                header, parent: BlockHeader): Result[void, string] =

  if not com.isLondon(header.blockNumber):
    # Verify BaseFee not present before EIP-1559 fork.
    if not header.baseFee.isZero:
      return err("invalid baseFee before London fork: have " & $header.baseFee & ", want <0>")
    let rc = com.validateGasLimit(header)
    if rc.isErr:
      return rc
  else:
    let rc = com.verifyEip1559Header(parent = parent,
                                     header = header)
    if rc.isErr:
      return rc

  return ok()

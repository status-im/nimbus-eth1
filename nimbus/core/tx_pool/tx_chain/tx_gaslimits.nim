# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  std/[math],
  ../../../common/common,
  ../../../constants,
  ../../pow/header,
  eth/[eip1559]

{.push raises: [].}

type
  TxChainGasLimitsPc* = tuple
    lwmTrg: int ##\
      ## VM executor may stop if this per centage of `trgLimit` has
      ## been reached.
    hwmMax: int ##\
      ## VM executor may stop if this per centage of `maxLimit` has
      ## been reached.
    gasFloor: GasInt
      ## minimum desired gas limit
    gasCeil: GasInt
      ## maximum desired gas limit

  TxChainGasLimits* = tuple
    gasLimit: GasInt ## Parent gas limit, used as a base for others
    minLimit: GasInt ## Minimum `gasLimit` for the packer
    lwmLimit: GasInt ## Low water mark for VM/exec packer
    trgLimit: GasInt ## The `gasLimit` for the packer, soft limit
    hwmLimit: GasInt ## High water mark for VM/exec packer
    maxLimit: GasInt ## May increase the `gasLimit` a bit, hard limit

const
  PRE_LONDON_GAS_LIMIT_TRG = ##\
    ## https://ethereum.org/en/developers/docs/blocks/#block-size
    15_000_000.GasInt

  PRE_LONDON_GAS_LIMIT_MAX = ##\
    ## https://ethereum.org/en/developers/docs/blocks/#block-size
    30_000_000.GasInt

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc setPostLondonLimits(gl: var TxChainGasLimits) =
  ## EIP-1559 conformant gas limit update
  gl.trgLimit = max(gl.gasLimit, GAS_LIMIT_MINIMUM)

  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1559.md
  # find in box: block.gas_used
  let delta = gl.trgLimit.floorDiv(GAS_LIMIT_ADJUSTMENT_FACTOR)
  gl.minLimit = gl.trgLimit + delta
  gl.maxLimit = gl.trgLimit - delta

  # Fringe case: use the middle between min/max
  if gl.minLimit <= GAS_LIMIT_MINIMUM:
    gl.minLimit = GAS_LIMIT_MINIMUM
    gl.trgLimit = (gl.minLimit + gl.maxLimit) div 2


proc setPreLondonLimits(gl: var TxChainGasLimits) =
  ## Pre-EIP-1559 conformant gas limit update
  gl.maxLimit = PRE_LONDON_GAS_LIMIT_MAX

  const delta = (PRE_LONDON_GAS_LIMIT_TRG - GAS_LIMIT_MINIMUM) div 2

  # Just made up to be convenient for the packer
  if gl.gasLimit <= GAS_LIMIT_MINIMUM + delta:
    gl.minLimit = max(gl.gasLimit, GAS_LIMIT_MINIMUM)
    gl.trgLimit = PRE_LONDON_GAS_LIMIT_TRG
  else:
    # This setting preserves the setting from the parent block
    gl.minLimit = gl.gasLimit - delta
    gl.trgLimit = gl.gasLimit

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc gasLimitsGet*(com: CommonRef; parent: BlockHeader; parentLimit: GasInt;
                   pc: TxChainGasLimitsPc): TxChainGasLimits =
  ## Calculate gas limits for the next block header.
  result.gasLimit = parentLimit

  if com.isLondon(parent.blockNumber+1):
    result.setPostLondonLimits
  else:
    result.setPreLondonLimits

  # VM/exec low/high water marks, optionally provided for packer
  result.lwmLimit = max(
    result.minLimit, (result.trgLimit * pc.lwmTrg + 50) div 100)

  result.hwmLimit = max(
    result.trgLimit, (result.maxLimit * pc.hwmMax + 50) div 100)

  # override trgLimit, see https://github.com/status-im/nimbus-eth1/issues/1032
  if com.isLondon(parent.blockNumber+1):
    var parentGasLimit = parent.gasLimit
    if not com.isLondon(parent.blockNumber):
      # Bump by 2x
      parentGasLimit = parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
    result.trgLimit = calcGasLimit1559(parentGasLimit, desiredLimit = pc.gasCeil)
  else:
    result.trgLimit = computeGasLimit(
      parent.gasUsed,
      parent.gasLimit,
      gasFloor = pc.gasFloor,
      gasCeil = pc.gasCeil)

proc gasLimitsGet*(com: CommonRef; parent: BlockHeader;
                   pc: TxChainGasLimitsPc): TxChainGasLimits =
  ## Variant of `gasLimitsGet()`
  com.gasLimitsGet(parent, parent.gasLimit, pc)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

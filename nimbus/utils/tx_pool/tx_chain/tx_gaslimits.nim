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
  ../../../chain_config,
  ../../../constants,
  ../../../forks,
  ../../../vm_types,
  eth/[common]

{.push raises: [Defect].}

type
  TxPoolGasLimits* = tuple
    minLimit: GasInt ## Minimum `gasLimit` for the packer
    lwmLimit: GasInt ## Low water mark for VM/exec extra packer
    trgLimit: GasInt ## The `gasLimit` for the packer, soft limit
    maxLimit: GasInt ## May increase the `gasLimit` a bit, hard limit

const
  PRE_LONDON_GAS_LIMIT_TRG = ##\
    ## https://ethereum.org/en/developers/docs/blocks/#block-size
    15_000_000.GasInt

  PRE_LONDON_GAS_LIMIT_MAX = ##\
    ## https://ethereum.org/en/developers/docs/blocks/#block-size
    30_000_000.GasInt

  TRG_THRESHOLD_PER_CENT = ##\
    ## VM executor stops if this per centage of `trgGasLimit` has been reached.
    90

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc setPostLondonLimits(gl: var TxPoolGasLimits; gasLimit: GasInt) =
  ## EIP-1559 conformant gas limit update
  gl.trgLimit = max(gasLimit, GAS_LIMIT_MINIMUM)

  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1559.md
  # find in box: block.gas_used
  let delta = gl.trgLimit.floorDiv(GAS_LIMIT_ADJUSTMENT_FACTOR)
  gl.minLimit = gl.trgLimit + delta
  gl.maxLimit = gl.trgLimit - delta

  # Fringe case: use the middle between min/max
  if gl.minLimit <= GAS_LIMIT_MINIMUM:
    gl.minLimit = GAS_LIMIT_MINIMUM
    gl.trgLimit = (gl.minLimit + gl.maxLimit) div 2


proc setPreLondonLimits(gl: var TxPoolGasLimits; gasLimit: GasInt) =
  ## Pre-EIP-1559 conformant gas limit update
  gl.maxLimit = PRE_LONDON_GAS_LIMIT_MAX

  const delta = (PRE_LONDON_GAS_LIMIT_TRG - GAS_LIMIT_MINIMUM) div 2

  # Just made up to be convenient for the packer
  if gasLimit <= GAS_LIMIT_MINIMUM + delta:
    gl.minLimit = max(gasLimit, GAS_LIMIT_MINIMUM)
    gl.trgLimit = PRE_LONDON_GAS_LIMIT_TRG
  else:
    # This setting preserves the setting from the parent block
    gl.minLimit = gasLimit - delta
    gl.trgLimit = gasLimit

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc gasLimitsGet*(vmState: BaseVMState;
                   parentGasLimit: GasInt): TxPoolGasLimits =
  ## Calculate gas limits for the next block header.

  let nextFork =
    vmState.chainDB.config.toFork(vmState.blockHeader.blockNumber + 1)

  if FkLondon <= nextFork:
    result.setPostLondonLimits(parentGasLimit)
  else:
    result.setPreLondonLimits(parentGasLimit)

  # VM/exec low water mark, optionally provided for packer
  result.lwmLimit = max(
    result.minLimit, (result.trgLimit * TRG_THRESHOLD_PER_CENT + 50) div 100)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

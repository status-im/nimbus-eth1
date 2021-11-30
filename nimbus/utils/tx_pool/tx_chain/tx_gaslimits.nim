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
  ../../../db/db_chain,
  ../../../constants,
  ../../../forks,
  eth/[common]

{.push raises: [Defect].}

type
  TxChainGasLimitsPc* = tuple
    lwmTrg: int ##\
      ## VM executor may stop if this per centage of `trgLimit` has
      ## been reached.
    hwmMax: int ##\
      ## VM executor may stop if this per centage of `maxLimit` has
      ## been reached.

  TxChainGasLimits* = tuple
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

proc setPostLondonLimits(gl: var TxChainGasLimits; gasLimit: GasInt) =
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


proc setPreLondonLimits(gl: var TxChainGasLimits; gasLimit: GasInt) =
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

proc gasLimitsGet*(db: BaseChainDB; parent: BlockHeader; parentLimit: GasInt;
                   pc: TxChainGasLimitsPc): TxChainGasLimits =
  ## Calculate gas limits for the next block header.

  let nextFork = db.config.toFork(parent.blockNumber + 1)

  if FkLondon <= nextFork:
    result.setPostLondonLimits(parentLimit)
  else:
    result.setPreLondonLimits(parentLimit)

  # VM/exec low/high water marks, optionally provided for packer
  result.lwmLimit = max(
    result.minLimit, (result.trgLimit * pc.lwmTrg + 50) div 100)

  result.hwmLimit = max(
    result.trgLimit, (result.maxLimit * pc.hwmMax + 50) div 100)


proc gasLimitsGet*(db: BaseChainDB; parent: BlockHeader;
                   pc: TxChainGasLimitsPc): TxChainGasLimits =
  ## Variant of `gasLimitsGet()`
  db.gasLimitsGet(parent, parent.gasLimit, pc)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

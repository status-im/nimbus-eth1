# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Block Data
## ===============================
##

import
  eth/common,
  ../../computation,
  ../../stack,
  ../../async/operations,
  ../op_codes,
  ./oph_defs

{.push raises: [CatchableError].} # basically the annotation type of a `Vm2OpFn`

when not defined(evmc_enabled):
  import ../../state

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  blockhashOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x40, Get the hash of one of the 256 most recent complete blocks.
    let cpt = k.cpt
    let (blockNumber) = cpt.stack.popInt(1)
    cpt.asyncChainTo(ifNecessaryGetBlockHeaderByNumber(cpt.vmState, blockNumber)):
      cpt.stack.push:
        cpt.getBlockHash(blockNumber)

  coinBaseOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x41, Get the block's beneficiary address.
    k.cpt.stack.push:
      k.cpt.getCoinbase

  timestampOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x42, Get the block's timestamp.
    k.cpt.stack.push:
      k.cpt.getTimestamp

  blocknumberOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x43, Get the block's number.
    k.cpt.stack.push:
      k.cpt.getBlockNumber

  difficultyOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x44, Get the block's difficulty
    k.cpt.stack.push:
      k.cpt.getDifficulty

  gasLimitOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x45, Get the block's gas limit
    k.cpt.stack.push:
      k.cpt.getGasLimit

  chainIdOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x46, Get current chain’s EIP-155 unique identifier.
    k.cpt.stack.push:
      k.cpt.getChainId

  selfBalanceOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x47, Get current contract's balance.
    let cpt = k.cpt
    cpt.asyncChainTo(ifNecessaryGetAccount(cpt.vmState, cpt.msg.contractAddress)):
      cpt.stack.push:
        cpt.getBalance(cpt.msg.contractAddress)

  baseFeeOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x48, Get the block's base fee.
    k.cpt.stack.push:
      k.cpt.getBaseFee

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecBlockData*: seq[Vm2OpExec] = @[

    (opCode: Blockhash,       ## 0x40, Hash of some most recent complete block
     forks: Vm2OpAllForks,
     name: "blockhash",
     info: "Get the hash of one of the 256 most recent complete blocks",
     exec: (prep: vm2OpIgnore,
            run:  blockhashOp,
            post: vm2OpIgnore)),

    (opCode: Coinbase,        ## 0x41, Beneficiary address
     forks: Vm2OpAllForks,
     name: "coinbase",
     info: "Get the block's beneficiary address",
     exec: (prep: vm2OpIgnore,
            run:  coinBaseOp,
            post: vm2OpIgnore)),

    (opCode: Timestamp,       ## 0x42, Block timestamp.
     forks: Vm2OpAllForks,
     name: "timestamp",
     info: "Get the block's timestamp",
     exec: (prep: vm2OpIgnore,
            run:  timestampOp,
            post: vm2OpIgnore)),

    (opCode: Number,          ## 0x43, Block number
     forks: Vm2OpAllForks,
     name: "blockNumber",
     info: "Get the block's number",
     exec: (prep: vm2OpIgnore,
            run:  blocknumberOp,
            post: vm2OpIgnore)),

    (opCode: Difficulty,      ## 0x44, Block difficulty
     forks: Vm2OpAllForks,
     name: "difficulty",
     info: "Get the block's difficulty",
     exec: (prep: vm2OpIgnore,
            run:  difficultyOp,
            post: vm2OpIgnore)),

    (opCode: GasLimit,        ## 0x45, Block gas limit
     forks: Vm2OpAllForks,
     name: "gasLimit",
     info: "Get the block's gas limit",
     exec: (prep: vm2OpIgnore,
            run:  gasLimitOp,
            post: vm2OpIgnore)),

    (opCode: ChainIdOp,       ## 0x46, EIP-155 chain identifier
     forks: Vm2OpIstanbulAndLater,
     name: "chainId",
     info: "Get current chain’s EIP-155 unique identifier",
     exec: (prep: vm2OpIgnore,
            run:  chainIdOp,
            post: vm2OpIgnore)),

    (opCode: SelfBalance,     ## 0x47, Contract balance.
     forks: Vm2OpIstanbulAndLater,
     name: "selfBalance",
     info: "Get current contract's balance",
     exec: (prep: vm2OpIgnore,
            run:  selfBalanceOp,
            post: vm2OpIgnore)),

    (opCode: BaseFee,         ## 0x48, EIP-1559 Block base fee.
     forks: Vm2OpLondonAndLater,
     name: "baseFee",
     info: "Get current block's EIP-1559 base fee",
     exec: (prep: vm2OpIgnore,
            run:  baseFeeOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

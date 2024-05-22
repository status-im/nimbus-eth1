# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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

{.push raises: [].}

import
  eth/common,
  ../../computation,
  ../../stack,
  ../utils/utils_numeric,
  ../op_codes,
  ./oph_defs

when not defined(evmc_enabled):
  import ../../state

# Annotation helpers
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  blockhashOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x40, Get the hash of one of the 256 most recent complete blocks.
    let cpt = k.cpt
    let (blockNumber) = cpt.stack.popInt(1)
    block:
      cpt.stack.push:
        cpt.getBlockHash(blockNumber)

  coinBaseOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x41, Get the block's beneficiary address.
    k.cpt.stack.push:
      k.cpt.getCoinbase

  timestampOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x42, Get the block's timestamp.
    k.cpt.stack.push:
      k.cpt.getTimestamp

  blocknumberOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x43, Get the block's number.
    k.cpt.stack.push:
      k.cpt.getBlockNumber

  difficultyOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x44, Get the block's difficulty
    k.cpt.stack.push:
      k.cpt.getDifficulty

  gasLimitOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x45, Get the block's gas limit
    k.cpt.stack.push:
      k.cpt.getGasLimit

  chainIdOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x46, Get current chain’s EIP-155 unique identifier.
    k.cpt.stack.push:
      k.cpt.getChainId

  selfBalanceOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x47, Get current contract's balance.
    let cpt = k.cpt
    block:
      cpt.stack.push:
        cpt.getBalance(cpt.msg.contractAddress)

  baseFeeOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x48, Get the block's base fee.
    k.cpt.stack.push:
      k.cpt.getBaseFee

  blobHashOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x49, Get current transaction's EIP-4844 versioned hash.
    let index = k.cpt.stack.popInt().safeInt
    let len = k.cpt.getVersionedHashesLen

    if index < len:
      k.cpt.stack.push:
        k.cpt.getVersionedHash(index)
    else:
      k.cpt.stack.push:
        0

  blobBaseFeeOp: Vm2OpFn = proc (k: var Vm2Ctx) {.catchRaise.} =
    ## 0x4a, Get the block's base fee.
    k.cpt.stack.push:
      k.cpt.getBlobBaseFee


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
            post: vm2OpIgnore)),

    (opCode: BlobHash,        ## 0x49, EIP-4844 Transaction versioned hash
     forks: Vm2OpCancunAndLater,
     name: "blobHash",
     info: "Get current transaction's EIP-4844 versioned hash",
     exec: (prep: vm2OpIgnore,
            run:  blobHashOp,
            post: vm2OpIgnore)),

    (opCode: BlobBaseFee,     ## 0x4a, EIP-7516 Returns the current data-blob base-fee
     forks: Vm2OpCancunAndLater,
     name: "blobBaseFee",
     info: "Returns the current data-blob base-fee",
     exec: (prep: vm2OpIgnore,
            run:  blobBaseFeeOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

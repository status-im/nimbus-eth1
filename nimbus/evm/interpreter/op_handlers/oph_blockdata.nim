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
  ../../evm_errors,
  ../op_codes,
  ./oph_defs

when not defined(evmc_enabled):
  import ../../state

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc blockhashOp (k: var VmCtx): EvmResultVoid =
  ## 0x40, Get the hash of one of the 256 most recent complete blocks.
  let
    cpt = k.cpt
    blockNumber = ? cpt.stack.popInt()
    blockHash = cpt.getBlockHash(blockNumber.truncate(BlockNumber))

  cpt.stack.push blockHash

proc coinBaseOp (k: var VmCtx): EvmResultVoid =
  ## 0x41, Get the block's beneficiary address.
  k.cpt.stack.push k.cpt.getCoinbase

proc timestampOp (k: var VmCtx): EvmResultVoid =
  ## 0x42, Get the block's timestamp.
  k.cpt.stack.push k.cpt.getTimestamp

proc blocknumberOp (k: var VmCtx): EvmResultVoid =
  ## 0x43, Get the block's number.
  k.cpt.stack.push k.cpt.getBlockNumber

proc difficultyOp (k: var VmCtx): EvmResultVoid =
  ## 0x44, Get the block's difficulty
  k.cpt.stack.push k.cpt.getDifficulty

proc gasLimitOp (k: var VmCtx): EvmResultVoid =
  ## 0x45, Get the block's gas limit
  k.cpt.stack.push k.cpt.getGasLimit

proc chainIdOp (k: var VmCtx): EvmResultVoid =
  ## 0x46, Get current chain’s EIP-155 unique identifier.
  k.cpt.stack.push k.cpt.getChainId

proc selfBalanceOp (k: var VmCtx): EvmResultVoid =
  ## 0x47, Get current contract's balance.
  let cpt = k.cpt
  cpt.stack.push cpt.getBalance(cpt.msg.contractAddress)

proc baseFeeOp (k: var VmCtx): EvmResultVoid =
  ## 0x48, Get the block's base fee.
  k.cpt.stack.push k.cpt.getBaseFee

proc blobHashOp (k: var VmCtx): EvmResultVoid =
  ## 0x49, Get current transaction's EIP-4844 versioned hash.
  let
    index = ? k.cpt.stack.popSafeInt()
    len = k.cpt.getVersionedHashesLen

  if index < len:
    k.cpt.stack.push k.cpt.getVersionedHash(index)
  else:
    k.cpt.stack.push 0

proc blobBaseFeeOp (k: var VmCtx): EvmResultVoid =
  ## 0x4a, Get the block's base fee.
  k.cpt.stack.push k.cpt.getBlobBaseFee


# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecBlockData*: seq[VmOpExec] = @[

    (opCode: Blockhash,       ## 0x40, Hash of some most recent complete block
     forks: VmOpAllForks,
     name: "blockhash",
     info: "Get the hash of one of the 256 most recent complete blocks",
     exec: (prep: VmOpIgnore,
            run:  blockhashOp,
            post: VmOpIgnore)),

    (opCode: Coinbase,        ## 0x41, Beneficiary address
     forks: VmOpAllForks,
     name: "coinbase",
     info: "Get the block's beneficiary address",
     exec: (prep: VmOpIgnore,
            run:  coinBaseOp,
            post: VmOpIgnore)),

    (opCode: Timestamp,       ## 0x42, Block timestamp.
     forks: VmOpAllForks,
     name: "timestamp",
     info: "Get the block's timestamp",
     exec: (prep: VmOpIgnore,
            run:  timestampOp,
            post: VmOpIgnore)),

    (opCode: Number,          ## 0x43, Block number
     forks: VmOpAllForks,
     name: "blockNumber",
     info: "Get the block's number",
     exec: (prep: VmOpIgnore,
            run:  blocknumberOp,
            post: VmOpIgnore)),

    (opCode: Difficulty,      ## 0x44, Block difficulty
     forks: VmOpAllForks,
     name: "difficulty",
     info: "Get the block's difficulty",
     exec: (prep: VmOpIgnore,
            run:  difficultyOp,
            post: VmOpIgnore)),

    (opCode: GasLimit,        ## 0x45, Block gas limit
     forks: VmOpAllForks,
     name: "gasLimit",
     info: "Get the block's gas limit",
     exec: (prep: VmOpIgnore,
            run:  gasLimitOp,
            post: VmOpIgnore)),

    (opCode: ChainIdOp,       ## 0x46, EIP-155 chain identifier
     forks: VmOpIstanbulAndLater,
     name: "chainId",
     info: "Get current chain’s EIP-155 unique identifier",
     exec: (prep: VmOpIgnore,
            run:  chainIdOp,
            post: VmOpIgnore)),

    (opCode: SelfBalance,     ## 0x47, Contract balance.
     forks: VmOpIstanbulAndLater,
     name: "selfBalance",
     info: "Get current contract's balance",
     exec: (prep: VmOpIgnore,
            run:  selfBalanceOp,
            post: VmOpIgnore)),

    (opCode: BaseFee,         ## 0x48, EIP-1559 Block base fee.
     forks: VmOpLondonAndLater,
     name: "baseFee",
     info: "Get current block's EIP-1559 base fee",
     exec: (prep: VmOpIgnore,
            run:  baseFeeOp,
            post: VmOpIgnore)),

    (opCode: BlobHash,        ## 0x49, EIP-4844 Transaction versioned hash
     forks: VmOpCancunAndLater,
     name: "blobHash",
     info: "Get current transaction's EIP-4844 versioned hash",
     exec: (prep: VmOpIgnore,
            run:  blobHashOp,
            post: VmOpIgnore)),

    (opCode: BlobBaseFee,     ## 0x4a, EIP-7516 Returns the current data-blob base-fee
     forks: VmOpCancunAndLater,
     name: "blobBaseFee",
     info: "Returns the current data-blob base-fee",
     exec: (prep: VmOpIgnore,
            run:  blobBaseFeeOp,
            post: VmOpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

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
  ../../computation,
  ../../stack,
  ../../evm_errors,
  ../utils/utils_numeric,
  ../op_codes,
  ./oph_defs

when not defined(evmc_enabled):
  import ../../state

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc blockhashOp(cpt: VmCpt): EvmResultVoid =
  ## 0x40, Get the hash of one of the 256 most recent complete blocks.
  template block256(top, number, conv) =
    if number > high(BlockNumber).u256:
      conv(zero(UInt256), top)
    else:
      conv(cpt.getBlockHash(number.truncate(BlockNumber)), top)

  cpt.stack.unaryWithTop(block256)

proc coinBaseOp(cpt: VmCpt): EvmResultVoid =
  ## 0x41, Get the block's beneficiary address.
  cpt.stack.push cpt.getCoinbase

proc timestampOp(cpt: VmCpt): EvmResultVoid =
  ## 0x42, Get the block's timestamp.
  cpt.stack.push cpt.getTimestamp

proc blocknumberOp(cpt: VmCpt): EvmResultVoid =
  ## 0x43, Get the block's number.
  cpt.stack.push cpt.getBlockNumber

proc difficultyOp(cpt: VmCpt): EvmResultVoid =
  ## 0x44, Get the block's difficulty
  cpt.stack.push cpt.getDifficulty

proc gasLimitOp(cpt: VmCpt): EvmResultVoid =
  ## 0x45, Get the block's gas limit
  cpt.stack.push cpt.getGasLimit

proc chainIdOp(cpt: VmCpt): EvmResultVoid =
  ## 0x46, Get current chain’s EIP-155 unique identifier.
  cpt.stack.push cpt.getChainId

proc selfBalanceOp(cpt: VmCpt): EvmResultVoid =
  ## 0x47, Get current contract's balance.
  cpt.stack.push cpt.getBalance(cpt.msg.contractAddress)

proc baseFeeOp(cpt: VmCpt): EvmResultVoid =
  ## 0x48, Get the block's base fee.
  cpt.stack.push cpt.getBaseFee

proc blobHashOp(cpt: VmCpt): EvmResultVoid =
  ## 0x49, Get current transaction's EIP-4844 versioned hash.
  template blob256(top, number, conv) =
    let
      index = number.safeInt
      len = cpt.getVersionedHashesLen

    if index < len:
      conv(cpt.getVersionedHash(index).data, top)
    else:
      conv(zero(UInt256), top)

  cpt.stack.unaryWithTop(blob256)

proc blobBaseFeeOp(cpt: VmCpt): EvmResultVoid =
  ## 0x4a, Get the block's base fee.
  cpt.stack.push cpt.getBlobBaseFee


# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecBlockData*: seq[VmOpExec] = @[

    (opCode: Blockhash,       ## 0x40, Hash of some most recent complete block
     forks: VmOpAllForks,
     name: "blockhash",
     info: "Get the hash of one of the 256 most recent complete blocks",
     exec: blockhashOp),


    (opCode: Coinbase,        ## 0x41, Beneficiary address
     forks: VmOpAllForks,
     name: "coinbase",
     info: "Get the block's beneficiary address",
     exec: coinBaseOp),


    (opCode: Timestamp,       ## 0x42, Block timestamp.
     forks: VmOpAllForks,
     name: "timestamp",
     info: "Get the block's timestamp",
     exec: timestampOp),


    (opCode: Number,          ## 0x43, Block number
     forks: VmOpAllForks,
     name: "blockNumber",
     info: "Get the block's number",
     exec: blocknumberOp),


    (opCode: Difficulty,      ## 0x44, Block difficulty
     forks: VmOpAllForks,
     name: "difficulty",
     info: "Get the block's difficulty",
     exec: difficultyOp),


    (opCode: GasLimit,        ## 0x45, Block gas limit
     forks: VmOpAllForks,
     name: "gasLimit",
     info: "Get the block's gas limit",
     exec: gasLimitOp),


    (opCode: ChainIdOp,       ## 0x46, EIP-155 chain identifier
     forks: VmOpIstanbulAndLater,
     name: "chainId",
     info: "Get current chain’s EIP-155 unique identifier",
     exec: chainIdOp),


    (opCode: SelfBalance,     ## 0x47, Contract balance.
     forks: VmOpIstanbulAndLater,
     name: "selfBalance",
     info: "Get current contract's balance",
     exec: selfBalanceOp),


    (opCode: BaseFee,         ## 0x48, EIP-1559 Block base fee.
     forks: VmOpLondonAndLater,
     name: "baseFee",
     info: "Get current block's EIP-1559 base fee",
     exec: baseFeeOp),


    (opCode: BlobHash,        ## 0x49, EIP-4844 Transaction versioned hash
     forks: VmOpCancunAndLater,
     name: "blobHash",
     info: "Get current transaction's EIP-4844 versioned hash",
     exec: blobHashOp),


    (opCode: BlobBaseFee,     ## 0x4a, EIP-7516 Returns the current data-blob base-fee
     forks: VmOpCancunAndLater,
     name: "blobBaseFee",
     info: "Returns the current data-blob base-fee",
     exec: blobBaseFeeOp)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

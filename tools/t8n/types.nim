# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables, json],
  eth/common,
  ../../nimbus/common/chain_config,
  ../common/types

export
  types

type
  T8NExitCode* = distinct int

  T8NError* = object of CatchableError
    exitCode*: T8NExitCode

  Ommer* = object
    delta*: uint64
    address*: EthAddress

  EnvStruct* = object
    currentCoinbase*: EthAddress
    currentDifficulty*: Option[DifficultyInt]
    currentRandom*: Option[Hash256]
    parentDifficulty*: Option[DifficultyInt]
    currentGasLimit*: GasInt
    currentNumber*: BlockNumber
    currentTimestamp*: EthTime
    parentTimestamp*: EthTime
    blockHashes*: Table[uint64, Hash256]
    ommers*: seq[Ommer]
    currentBaseFee*: Option[UInt256]
    parentUncleHash*: Hash256
    parentBaseFee*: Option[UInt256]
    parentGasUsed*: Option[GasInt]
    parentGasLimit*: Option[GasInt]
    withdrawals*: Option[seq[Withdrawal]]
    currentBlobGasUsed*: Option[uint64]
    currentExcessBlobGas*: Option[uint64]
    parentBlobGasUsed*: Option[uint64]
    parentExcessBlobGas*: Option[uint64]
    parentBeaconBlockRoot*: Option[Hash256]

  TxsType* = enum
    TxsNone
    TxsRlp
    TxsJson

  TxsList* = object
    case txsType*: TxsType
    of TxsRlp: r*: Rlp
    of TxsJson: n*: JsonNode
    else: discard

  TransContext* = object
    alloc*: GenesisAlloc
    txs*: TxsList
    env*: EnvStruct

  RejectedTx* = object
    index*: int
    error*: string

  TxReceipt* = object
    txType*: TxType
    root*: Hash256
    status*: bool
    cumulativeGasUsed*: GasInt
    logsBloom*: BloomFilter
    logs*: seq[Log]
    transactionHash*: Hash256
    contractAddress*: EthAddress
    gasUsed*: GasInt
    blockHash*: Hash256
    transactionIndex*: int

  # ExecutionResult contains the execution status after running a state test, any
  # error that might have occurred and a dump of the final state if requested.
  ExecutionResult* = object
    stateRoot*: Hash256
    txRoot*: Hash256
    receiptsRoot*: Hash256
    logsHash*: Hash256
    bloom*: BloomFilter
    receipts*: seq[TxReceipt]
    rejected*: seq[RejectedTx]
    currentDifficulty*: Option[DifficultyInt]
    gasUsed*: GasInt
    currentBaseFee*: Option[UInt256]
    withdrawalsRoot*: Option[Hash256]
    blobGasUsed*: Option[uint64]
    currentExcessBlobGas*: Option[uint64]

const
  ErrorEVM*              = 2.T8NExitCode
  ErrorConfig*           = 3.T8NExitCode
  ErrorMissingBlockhash* = 4.T8NExitCode

  ErrorJson* = 10.T8NExitCode
  ErrorIO*   = 11.T8NExitCode
  ErrorRlp*  = 12.T8NExitCode

proc newError*(code: T8NExitCode, msg: string): ref T8NError =
  (ref T8NError)(exitCode: code, msg: msg)

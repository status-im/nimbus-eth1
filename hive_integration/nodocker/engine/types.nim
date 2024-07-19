# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[typetraits, strutils],
  chronicles,
  eth/common,
  nimcrypto/[sysrand, sha2],
  stew/[byteutils, endians2],
  web3/eth_api_types,
  web3/engine_api_types,
  web3/execution_types,
  ../../../nimbus/beacon/web3_eth_conv,
  ../../../nimbus/utils/utils

from ../../../nimbus/common/chain_config import NetworkParams

export execution_types, web3_eth_conv

type
  EngineFork* = enum
    ForkNone = "none"
    ForkParis = "Merge"
    ForkShanghai = "Shanghai"
    ForkCancun = "Cancun"

  BaseSpec* = ref object of RootObj
    txType*: Opt[TxType]

    # CL Mocker configuration for slots to `safe` and `finalized` respectively
    slotsToSafe*: int
    slotsToFinalized*: int
    safeSlotsToImportOptimistically*: int
    blockTimestampIncrement*: int
    timeoutSeconds*: int
    mainFork*: EngineFork
    genesisTimestamp*: int
    forkHeight*: int
    forkTime*: uint64
    previousForkTime*: uint64
    getGenesisFn*: proc(cs: BaseSpec, param: NetworkParams)

  TestDesc* = object
    name*: string
    about*: string
    run*: proc(spec: BaseSpec): bool
    spec*: BaseSpec

  ExecutableData* = object
    basePayload*: ExecutionPayload
    beaconRoot*: Opt[common.Hash256]
    attr*: PayloadAttributes
    versionedHashes*: Opt[seq[common.Hash256]]

const
  DefaultTimeout* = 60 # seconds
  DefaultSleep* = 1
  prevRandaoContractAddr* =
    hexToByteArray[20]("0000000000000000000000000000000000000316")
  GenesisTimestamp* = 0x1234
  Head* = "latest"
  Pending* = "pending"
  Finalized* = "finalized"
  Safe* = "safe"

func toAddress*(x: UInt256): EthAddress =
  var
    mm = x.toByteArrayBE
    x = 0
  for i in 12 .. 31:
    result[x] = mm[i]
    inc x

const ZeroAddr* = toAddress(0.u256)

func toHash*(x: UInt256): common.Hash256 =
  common.Hash256(data: x.toByteArrayBE)

func timestampToBeaconRoot*(timestamp: Quantity): FixedBytes[32] =
  # Generates a deterministic hash from the timestamp
  let h = sha2.sha256.digest(timestamp.uint64.toBytesBE)
  FixedBytes[32](h.data)

proc randomBytes*(_: type common.Hash256): common.Hash256 =
  doAssert randomBytes(result.data) == 32

proc randomBytes*(_: type common.EthAddress): common.EthAddress =
  doAssert randomBytes(result) == 20

proc randomBytes*(_: type Web3Hash): Web3Hash =
  var res: array[32, byte]
  doAssert randomBytes(res) == 32
  result = Web3Hash(res)

proc clone*[T](x: T): T =
  result = T()
  result[] = x[]

template testCond*(expr: untyped) =
  if not (expr):
    return false

template testCond*(expr, body: untyped) =
  if not (expr):
    body
    return false

proc `==`*(a: Opt[BlockHash], b: Opt[common.Hash256]): bool =
  if a.isNone and b.isNone:
    return true
  if a.isSome and b.isSome:
    return a.get() == b.get().data.BlockHash

template expectErrorCode*(res: untyped, errCode: int) =
  testCond res.isErr:
    error "unexpected result, want error, get ok"
  testCond res.error.find($errCode) != -1:
    error "unexpected error code", expect = errCode, got = res.error

template expectNoError*(res: untyped) =
  testCond res.isOk

template expectPayload*(res: untyped, payload: ExecutionPayload) =
  testCond res.isOk:
    error "Unexpected getPayload Error", msg = res.error
  let x = res.get
  when typeof(x) is ExecutionPayloadV1:
    testCond x == payload.V1:
      error "getPayloadV1 return mismatch payload"
  elif typeof(x) is GetPayloadV2Response:
    testCond x.executionPayload == payload.V1V2:
      error "getPayloadV2 return mismatch payload"
  else:
    testCond x.executionPayload == payload.V3:
      error "getPayloadV3 return mismatch payload"

template expectWithdrawalsRoot*(res: untyped, wdRoot: Opt[common.Hash256]) =
  testCond res.isOk:
    error "Unexpected error", msg = res.error
  let h = res.get
  testCond h.withdrawalsRoot == wdRoot:
    error "wdroot mismatch"

template expectBalanceEqual*(res: untyped, expectedBalance: UInt256) =
  testCond res.isOk:
    error "Unexpected error", msg = res.error
  testCond res.get == expectedBalance:
    error "balance mismatch", expect = expectedBalance, get = res.get

template expectLatestValidHash*(res: untyped, expectedHash: Web3Hash) =
  testCond res.isOk:
    error "Unexpected error", msg = res.error
  let s = res.get
  when s is PayloadStatusV1:
    testCond s.latestValidHash.isSome:
      error "Expect latest valid hash isSome", msg = s.validationError.get("NO MSG")
    testCond s.latestValidHash.get == expectedHash:
      error "latest valid hash mismatch",
        expect = expectedHash.short, get = s.latestValidHash.get.short
  else:
    testCond s.payloadStatus.latestValidHash.isSome:
      error "Expect latest valid hash isSome"
    testCond s.payloadStatus.latestValidHash.get == expectedHash:
      error "latest valid hash mismatch",
        expect = expectedHash.short, get = s.payloadStatus.latestValidHash.get.short

template expectLatestValidHash*(res: untyped) =
  testCond res.isOk:
    error "Unexpected error", msg = res.error
  let s = res.get
  when s is ForkchoiceUpdatedResponse:
    testCond s.payloadStatus.latestValidHash.isNone:
      error "Expect latest valid hash isNone"
  else:
    testCond s.latestValidHash.isNone:
      error "Expect latest valid hash isNone"

template expectErrorCode*(res: untyped, errCode: int, expectedDesc: string) =
  testCond res.isErr:
    error "unexpected result, want error, get ok"
  testCond res.error.find($errCode) != -1:
    fatal "DEBUG", msg = expectedDesc, expected = errCode, got = res.error

template expectNoError*(res: untyped, expectedDesc: string) =
  testCond res.isOk:
    fatal "DEBUG", msg = expectedDesc, err = res.error

template expectStatusEither*(res: untyped, cond: openArray[PayloadExecutionStatus]) =
  testCond res.isOk:
    error "Unexpected expectStatusEither error", msg = res.error
  let s = res.get()
  when s is PayloadStatusV1:
    testCond s.status in cond:
      error "Unexpected expectStatusEither status",
        expect = cond, get = s.status, msg = s.validationError.get("NO MSG")
  else:
    testCond s.payloadStatus.status in cond:
      error "Unexpected expectStatusEither status",
        expect = cond,
        get = s.payloadStatus.status,
        msg = s.payloadStatus.validationError.get("NO MSG")

template expectNoValidationError*(res: untyped) =
  testCond res.isOk:
    error "Unexpected expectNoValidationError error", msg = res.error
  let s = res.get()
  when s is PayloadStatusV1:
    testCond s.validationError.isNone:
      error "Unexpected validation error isSome"
  else:
    testCond s.payloadStatus.validationError.isNone:
      error "Unexpected validation error isSome"

template expectPayloadStatus*(res: untyped, cond: PayloadExecutionStatus) =
  testCond res.isOk:
    error "Unexpected FCU Error", msg = res.error
  let s = res.get()
  testCond s.payloadStatus.status == cond:
    error "Unexpected FCU status", expect = cond, get = s.payloadStatus.status

template expectStatus*(res: untyped, cond: PayloadExecutionStatus) =
  testCond res.isOk:
    error "Unexpected newPayload error", msg = res.error
  let s = res.get()
  testCond s.status == cond:
    error "Unexpected newPayload status", expect = cond, get = s.status

template expectPayloadID*(res: untyped, id: Opt[PayloadID]) =
  testCond res.isOk:
    error "Unexpected expectPayloadID Error", msg = res.error
  let s = res.get()
  testCond s.payloadId == id:
    error "Unexpected expectPayloadID payloadID", expect = id, get = s.payloadId

template expectError*(res: untyped) =
  testCond res.isErr:
    error "Unexpected expectError, got noerror"

template expectHash*(res: untyped, hash: common.Hash256) =
  testCond res.isOk:
    error "Unexpected expectHash Error", msg = res.error
  let s = res.get()
  testCond s.blockHash == hash:
    error "Unexpected expectHash", expect = hash.short, get = s.blockHash.short

template expectStorageEqual*(res: untyped, expectedValue: FixedBytes[32]) =
  testCond res.isOk:
    error "expectStorageEqual", msg = res.error
  testCond res.get == expectedValue:
    error "invalid storage", get = res.get, expect = expectedValue

template expectBlobGasUsed*(res: untyped, expected: uint64) =
  testCond res.isOk:
    error "expectBlobGasUsed", msg = res.error
  let rec = res.get
  testCond rec.blobGasUsed.isSome:
    error "expect blobGasUsed isSome"
  testCond rec.blobGasUsed.get == expected:
    error "expectBlobGasUsed", expect = expected, get = rec.blobGasUsed.get

template expectBlobGasPrice*(res: untyped, expected: UInt256) =
  testCond res.isOk:
    error "expectBlobGasPrice", msg = res.error
  let rec = res.get
  testCond rec.blobGasPrice.isSome:
    error "expect blobGasPrice isSome"
  testCond rec.blobGasPrice.get == expected:
    error "expectBlobGasPrice", expect = expected, get = rec.blobGasPrice.get

template expectNumber*(res: untyped, expected: uint64) =
  testCond res.isOk:
    error "expectNumber", msg = res.error
  testCond res.get == expected:
    error "expectNumber", expect = expected, get = res.get

template expectTransactionHash*(res: untyped, expected: common.Hash256) =
  testCond res.isOk:
    error "expectTransactionHash", msg = res.error
  let rec = res.get
  testCond rec.txHash == expected:
    error "expectTransactionHash", expect = expected.short, get = rec.txHash.short

template expectPayloadParentHash*(res: untyped, expected: Web3Hash) =
  testCond res.isOk:
    error "expectPayloadParentHash", msg = res.error
  let rec = res.get
  testCond rec.executionPayload.parentHash == expected:
    error "expectPayloadParentHash",
      expect = expected.short, get = rec.executionPayload.parentHash.short

template expectBlockHash*(res: untyped, expected: common.Hash256) =
  testCond res.isOk:
    error "expectBlockHash", msg = res.error
  let rec = res.get
  testCond rec.blockHash == expected:
    error "expectBlockHash", expect = expected.short, get = rec.blockHash.short

func timestamp*(x: ExecutableData): auto =
  x.basePayload.timestamp

func parentHash*(x: ExecutableData): auto =
  x.basePayload.parentHash

func blockHash*(x: ExecutableData): auto =
  x.basePayload.blockHash

func blockNumber*(x: ExecutableData): auto =
  x.basePayload.blockNumber

func stateRoot*(x: ExecutableData): auto =
  x.basePayload.stateRoot

func version*(x: ExecutableData): auto =
  x.basePayload.version

func V1V2*(x: ExecutableData): auto =
  x.basePayload.V1V2

proc `parentHash=`*(x: var ExecutableData, val: auto) =
  x.basePayload.parentHash = val

proc `blockHash=`*(x: var ExecutableData, val: auto) =
  x.basePayload.blockHash = val

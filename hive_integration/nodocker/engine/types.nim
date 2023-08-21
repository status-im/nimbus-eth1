import
  std/[options, times, strutils, typetraits],
  web3/ethtypes,
  ../../../nimbus/rpc/merge/mergeutils,
  ../../../nimbus/rpc/execution_types,
  web3/engine_api_types,
  eth/common/eth_types_rlp

from web3/ethtypes as web3types import nil

export
  ethtypes,
  engine_api_types

import eth/common/eth_types as common

type
  BaseSpec* = ref object of RootObj
    txType*: Option[TxType]

  TestDesc* = object
    name* : string
    about*: string
    run*  : proc(spec: BaseSpec): bool
    spec* : BaseSpec

  Web3Hash256* = web3types.Hash256
  Web3Address* = web3types.Address
  Web3Bloom* = web3types.FixedBytes[256]
  Web3Quantity* = web3types.Quantity
  Web3PrevRandao* = web3types.FixedBytes[32]
  Web3ExtraData* = web3types.DynamicBytes[0, 32]

template testCond*(expr: untyped) =
  if not (expr):
    return false

template testCond*(expr, body: untyped) =
  if not (expr):
    body
    return false

proc `$`*(x: Option[common.Hash256]): string =
  if x.isNone:
    "none"
  else:
    $x.get()

proc `$`*(x: Option[BlockHash]): string =
  if x.isNone:
    "none"
  else:
    $x.get()

proc `$`*(x: Option[PayloadID]): string =
  if x.isNone:
    "none"
  else:
    x.get().toHex

func w3Hash*(x: common.Hash256): Web3Hash256 =
  Web3Hash256 x.data

func w3Hash*(x: Option[common.Hash256]): Option[BlockHash] =
  if x.isNone:
    return none(BlockHash)
  some(BlockHash x.get.data)

proc w3Hash*(x: common.BlockHeader): BlockHash =
  BlockHash x.blockHash.data

func w3Qty*(a: EthTime, b: int): Quantity =
  Quantity(a.toUnix + b.int64)

func w3Qty*(x: Option[uint64]): Option[Quantity] =
  if x.isNone:
    return none(Quantity)
  return some(Quantity x.get)

func u64*(x: Option[Quantity]): Option[uint64] =
  if x.isNone:
    return none(uint64)
  return some(uint64 x.get)

func w3PrevRandao*(): Web3PrevRandao =
  discard

func w3Address*(): Web3Address =
  discard

proc hash256*(h: Web3Hash256): common.Hash256 =
  common.Hash256(data: distinctBase h)

proc hash256*(h: Option[Web3Hash256]): Option[common.Hash256] =
  if h.isNone:
    return none(common.Hash256)
  some(hash256(h.get))

proc w3Withdrawal*(w: Withdrawal): WithdrawalV1 =
  WithdrawalV1(
    index: Quantity(w.index),
    validatorIndex: Quantity(w.validatorIndex),
    address: Address(w.address),
    amount: Quantity(w.amount)
  )

proc w3Withdrawals*(list: openArray[Withdrawal]): seq[WithdrawalV1] =
  result = newSeqOfCap[WithdrawalV1](list.len)
  for x in list:
    result.add w3Withdrawal(x)

proc withdrawal*(w: WithdrawalV1): Withdrawal =
  Withdrawal(
    index: uint64(w.index),
    validatorIndex: uint64(w.validatorIndex),
    address: distinctBase(w.address),
    amount: uint64(w.amount)
  )

proc withdrawals*(list: openArray[WithdrawalV1]): seq[Withdrawal] =
  result = newSeqOfCap[Withdrawal](list.len)
  for x in list:
    result.add withdrawal(x)

proc `==`*(a: Option[BlockHash], b: Option[common.Hash256]): bool =
  if a.isNone and b.isNone:
    return true
  if a.isSome and b.isSome:
    return a.get() == b.get().data.BlockHash

proc `==`*(a, b: TypedTransaction): bool =
  distinctBase(a) == distinctBase(b)

template testFCU*(res, cond: untyped, validHash: Option[common.Hash256], id = none(PayloadID)) =
  testCond res.isOk:
    error "Unexpected FCU Error", msg=res.error
  let s = res.get()
  testCond s.payloadStatus.status == PayloadExecutionStatus.cond:
    error "Unexpected FCU status", expect=PayloadExecutionStatus.cond, get=s.payloadStatus.status
  testCond s.payloadStatus.latestValidHash == validHash:
    error "Unexpected FCU latestValidHash", expect=validHash, get=s.payloadStatus.latestValidHash
  testCond s.payloadId == id:
    error "Unexpected FCU payloadID", expect=id, get=s.payloadId

template testFCU*(res, cond: untyped) =
  testCond res.isOk:
    error "Unexpected FCU Error", msg=res.error
  let s = res.get()
  testCond s.payloadStatus.status == PayloadExecutionStatus.cond:
    error "Unexpected FCU status", expect=PayloadExecutionStatus.cond, get=s.payloadStatus.status

template expectErrorCode*(res: untyped, errCode: int) =
  testCond res.isErr:
    error "unexpected result, want error, get ok"
  testCond res.error.find($errCode) != -1

template expectNoError*(res: untyped) =
  testCond res.isOk

template expectPayload*(res: untyped, payload: ExecutionPayload) =
  testCond res.isOk:
    error "Unexpected getPayload Error", msg=res.error
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

template expectStatus*(res, cond: untyped) =
  testCond res.isOk:
    error "Unexpected newPayload error", msg=res.error
  let s = res.get()
  testCond s.status == PayloadExecutionStatus.cond:
    error "Unexpected newPayload status", expect=PayloadExecutionStatus.cond, get=s.status

template expectWithdrawalsRoot*(res: untyped, h: common.BlockHeader, wdRoot: Option[common.Hash256]) =
  testCond res.isOk:
    error "Unexpected error", msg=res.error
  testCond h.withdrawalsRoot == wdRoot:
    error "wdroot mismatch"

template expectBalanceEqual*(res: untyped, expectedBalance: UInt256) =
  testCond res.isOk:
    error "Unexpected error", msg=res.error
  testCond res.get == expectedBalance:
    error "balance mismatch", expect=expectedBalance, get=res.get

template expectLatestValidHash*(res: untyped, expectedHash: Web3Hash256) =
  testCond res.isOk:
    error "Unexpected error", msg=res.error
  let s = res.get
  testCond s.latestValidHash.isSome:
    error "Expect latest valid hash isSome"
  testCond s.latestValidHash.get == expectedHash:
    error "latest valid hash mismatch", expect=expectedHash, get=s.latestValidHash.get

import
  std/[options, typetraits, strutils],
  eth/common,
  stew/byteutils,
  web3/ethtypes,
  web3/engine_api_types,
  ../../../nimbus/beacon/execution_types,
  ../../../nimbus/beacon/web3_eth_conv

type
  BaseSpec* = ref object of RootObj
    txType*: Option[TxType]

  TestDesc* = object
    name* : string
    about*: string
    run*  : proc(spec: BaseSpec): bool
    spec* : BaseSpec

const
  DefaultTimeout* = 60 # seconds
  DefaultSleep* = 1
  prevRandaoContractAddr* = hexToByteArray[20]("0000000000000000000000000000000000000316")

template testCond*(expr: untyped) =
  if not (expr):
    return false

template testCond*(expr, body: untyped) =
  if not (expr):
    body
    return false

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

template expectStatusEither*(res, cond1, cond2: untyped) =
  testCond res.isOk:
    error "Unexpected newPayload error", msg=res.error
  let s = res.get()
  testCond s.status == PayloadExecutionStatus.cond1 or s.status == PayloadExecutionStatus.cond2:
    error "Unexpected newPayload status",
      expect1=PayloadExecutionStatus.cond1,
      expect2=PayloadExecutionStatus.cond2,
      get=s.status

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

template expectLatestValidHash*(res: untyped, expectedHash: Web3Hash) =
  testCond res.isOk:
    error "Unexpected error", msg=res.error
  let s = res.get
  testCond s.latestValidHash.isSome:
    error "Expect latest valid hash isSome"
  testCond s.latestValidHash.get == expectedHash:
    error "latest valid hash mismatch", expect=expectedHash, get=s.latestValidHash.get

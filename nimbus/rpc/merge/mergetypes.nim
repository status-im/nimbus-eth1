import
  web3/engine_api_types,
  ../../db/db_chain,
  ./merger

import eth/common/eth_types except BlockHeader

export merger, eth_types


# The next few conversion functions are needed for responding
# to Engine API V1 requests. (For now, at least, it seems like
# the V1 API can be handled by the handler for the V2 API.)

func toPayloadV1*(p: ExecutionPayloadV2): ExecutionPayloadV1 =
  ExecutionPayloadV1(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions
  )

func toPayloadV2*(p: ExecutionPayloadV1): ExecutionPayloadV2 =
  ExecutionPayloadV2(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: none[seq[WithdrawalV1]]()
  )

func toPayloadAttributesV2*(a: PayloadAttributesV1): PayloadAttributesV2 =
  PayloadAttributesV2(
    timestamp: a.timestamp,
    prevRandao: a.prevRandao,
    suggestedFeeRecipient: a.suggestedFeeRecipient,
    withdrawals: none[seq[WithdrawalV1]]()
  )


type
  EthBlockHeader* = eth_types.BlockHeader

const
  # maxTrackedPayloads is the maximum number of prepared payloads the execution
  # engine tracks before evicting old ones. Ideally we should only ever track the
  # latest one; but have a slight wiggle room for non-ideal conditions.
  MaxTrackedPayloads = 10

  # maxTrackedHeaders is the maximum number of executed payloads the execution
  # engine tracks before evicting old ones. Ideally we should only ever track the
  # latest one; but have a slight wiggle room for non-ideal conditions.
  MaxTrackedHeaders = 10

type
  QueueItem[T] = object
    used: bool
    data: T

  SimpleQueue[M: static[int]; T] = object
    list: array[M, QueueItem[T]]

  PayloadItem = object
    id: PayloadID
    payload: ExecutionPayloadV2

  HeaderItem = object
    hash: Hash256
    header: EthBlockHeader

  EngineApiRef* = ref object
    merger: MergerRef
    payloadQueue: SimpleQueue[MaxTrackedPayloads, PayloadItem]
    headerQueue: SimpleQueue[MaxTrackedHeaders, HeaderItem]

template shiftRight[M, T](x: var SimpleQueue[M, T]) =
  x.list[1..^1] = x.list[0..^2]

proc put[M, T](x: var SimpleQueue[M, T], val: T) =
  x.shiftRight()
  x.list[0] = QueueItem[T](used: true, data: val)

iterator items[M, T](x: SimpleQueue[M, T]): T =
  for z in x.list:
    if z.used:
      yield z.data

template new*(_: type EngineApiRef): EngineApiRef =
  {.error: "EngineApiRef should be created with merger param " & $instantiationInfo().}

proc new*(_: type EngineApiRef, merger: MergerRef): EngineApiRef =
  EngineApiRef(
    merger: merger
  )

proc put*(api: EngineApiRef, hash: Hash256, header: EthBlockHeader) =
  api.headerQueue.put(HeaderItem(hash: hash, header: header))

proc get*(api: EngineApiRef, hash: Hash256, header: var EthBlockHeader): bool =
  for x in api.headerQueue:
    if x.hash == hash:
      header = x.header
      return true
  false

proc put*(api: EngineApiRef, id: PayloadID, payload: ExecutionPayloadV2) =
  api.payloadQueue.put(PayloadItem(id: id, payload: payload))

proc put*(api: EngineApiRef, id: PayloadID, payload: ExecutionPayloadV1) =
  put(api, id, payload.toPayloadV2)

proc get*(api: EngineApiRef, id: PayloadID, payload: var ExecutionPayloadV2): bool =
  for x in api.payloadQueue:
    if x.id == id:
      payload = x.payload
      return true
  false

proc get*(api: EngineApiRef, id: PayloadID, payload: var ExecutionPayloadV1): bool =
  var payloadV2: ExecutionPayloadV2
  let found = get(api, id, payloadV2)
  payload = payloadV2.toPayloadV1
  found

proc merger*(api: EngineApiRef): MergerRef =
  api.merger

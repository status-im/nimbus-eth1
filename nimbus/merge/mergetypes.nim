import
  web3/engine_api_types,
  ../db/db_chain,
  ./merger

import eth/common/eth_types except BlockHeader

export merger

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
    payload: ExecutionPayloadV1

  HeaderItem = object
    hash: Hash256
    header: EthBlockHeader

  EngineAPI* = ref object
    merger*: Merger
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

proc new*(_: type EngineAPI, db: BaseChainDB): EngineAPI =
  new result
  if not db.isNil:
    result.merger.init(db)

proc put*(api: EngineAPI, hash: Hash256, header: EthBlockHeader) =
  api.headerQueue.put(HeaderItem(hash: hash, header: header))

proc get*(api: EngineAPI, hash: Hash256, header: var EthBlockHeader): bool =
  for x in api.headerQueue:
    if x.hash == hash:
      header = x.header
      return true
  false

proc put*(api: EngineAPI, id: PayloadID, payload: ExecutionPayloadV1) =
  api.payloadQueue.put(PayloadItem(id: id, payload: payload))

proc get*(api: EngineAPI, id: PayloadID, payload: var ExecutionPayloadV1): bool =
  for x in api.payloadQueue:
    if x.id == id:
      payload = x.payload
      return true
  false

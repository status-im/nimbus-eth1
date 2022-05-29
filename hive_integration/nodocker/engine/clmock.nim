import
  std/[times, tables],
  chronicles,
  nimcrypto,
  stew/byteutils,
  eth/common, chronos,
  web3/engine_api_types,
  json_rpc/rpcclient,
  ../../../nimbus/merge/mergeutils,
  ../../../nimbus/debug,
  ./engine_client

# Consensus Layer Client Mock used to sync the Execution Clients once the TTD has been reached
type
  CLMocker* = ref object
    nextFeeRecipient*: EthAddress
    nextPayloadID: PayloadID

    # PoS Chain History Information
    prevRandaoHistory*:      Table[uint64, Hash256]
    executedPayloadHistory*: Table[uint64, ExecutionPayloadV1]

    # Latest broadcasted data using the PoS Engine API
    latestFinalizedNumber*: uint64
    latestFinalizedHeader*: common.BlockHeader
    latestPayloadBuilt*   : ExecutionPayloadV1
    latestExecutedPayload*: ExecutionPayloadV1
    latestForkchoice*     : ForkchoiceStateV1

    # Merge related
    firstPoSBlockNumber  : Option[uint64]
    ttdReached*          : bool

    client               : RpcClient
    ttd                  : DifficultyInt

  BlockProcessCallbacks* = object
    onPayloadProducerSelected*           : proc(): bool {.gcsafe.}
    onGetPayloadID*                      : proc(): bool {.gcsafe.}
    onGetPayload*                        : proc(): bool {.gcsafe.}
    onNewPayloadBroadcast*               : proc(): bool {.gcsafe.}
    onHeadBlockForkchoiceBroadcast*      : proc(): bool {.gcsafe.}
    onSafeBlockForkchoiceBroadcast*      : proc(): bool {.gcsafe.}
    onFinalizedBlockForkchoiceBroadcast* : proc(): bool {.gcsafe.}


proc init*(cl: CLMocker, client: RpcClient, ttd: DifficultyInt) =
  cl.client = client
  cl.ttd = ttd

proc newClMocker*(client: RpcClient, ttd: DifficultyInt): CLMocker =
  new result
  result.init(client, ttd)

proc waitForTTD*(cl: CLMocker): Future[bool] {.async.} =
  let (header, waitRes) = await cl.client.waitForTTD(cl.ttd)
  if not waitRes:
    error "timeout while waiting for TTD"
    return false

  cl.latestFinalizedHeader = header
  cl.ttdReached = true

  let headerHash = BlockHash(common.blockHash(cl.latestFinalizedHeader).data)
  cl.latestForkchoice.headBlockHash = headerHash
  cl.latestForkchoice.safeBlockHash = headerHash
  cl.latestForkchoice.finalizedBlockHash = headerHash
  cl.latestFinalizedNumber = cl.latestFinalizedHeader.blockNumber.truncate(uint64)

  let res = cl.client.forkchoiceUpdatedV1(cl.latestForkchoice)
  if res.isErr:
    error "forkchoiceUpdated error", msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "forkchoiceUpdated response",
      status=s.payloadStatus.status
    return false

  return true

proc pickNextPayloadProducer(cl: CLMocker): bool =
  let nRes = cl.client.blockNumber()
  if nRes.isErr:
    error "CLMocker: could not get block number", msg=nRes.error
    return false

  let lastBlockNumber = nRes.get
  if cl.latestFinalizedNumber != lastBlockNumber:
    return false

  var header: common.BlockHeader
  let hRes = cl.client.headerByNumber(lastBlockNumber, header)
  if hRes.isErr:
    error "CLMocker: Could not get block header", msg=hRes.error
    return false

  let lastBlockHash = header.blockHash
  if cl.latestFinalizedHeader.blockHash != lastBlockHash:
    error "CLMocker: Failed to obtain a client on the latest block number"
    return false

  return true

proc getNextPayloadID(cl: CLMocker): bool =
  # Generate a random value for the PrevRandao field
  var nextPrevRandao: Hash256
  doAssert nimcrypto.randomBytes(nextPrevRandao.data) == 32

  let timestamp = Quantity toUnix(cl.latestFinalizedHeader.timestamp + 1.seconds)
  let payloadAttributes = PayloadAttributesV1(
    timestamp:             timestamp,
    prevRandao:            FixedBytes[32] nextPrevRandao.data,
    suggestedFeeRecipient: Address cl.nextFeeRecipient,
  )

  # Save random value
  let number = cl.latestFinalizedHeader.blockNumber.truncate(uint64) + 1
  cl.prevRandaoHistory[number] = nextPrevRandao

  let res = cl.client.forkchoiceUpdatedV1(cl.latestForkchoice, some(payloadAttributes))
  if res.isErr:
    error "CLMocker: Could not send forkchoiceUpdatedV1", msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "CLMocker: Unexpected forkchoiceUpdated Response from Payload builder",
      status=s.payloadStatus.status

  doAssert s.payLoadID.isSome
  cl.nextPayloadID = s.payloadID.get()
  return true

proc getNextPayload(cl: CLMocker): bool =
  let res = cl.client.getPayloadV1(cl.nextPayloadID)
  if res.isErr:
    error "CLMocker: Could not getPayload",
      payloadID=toHex(cl.nextPayloadID)
    return false

  cl.latestPayloadBuilt = res.get()
  let header = toBlockHeader(cl.latestPayloadBuilt)
  let blockHash = BlockHash header.blockHash.data
  if blockHash != cl.latestPayloadBuilt.blockHash:
    error "getNextPayload blockHash mismatch",
      expected=cl.latestPayloadBuilt.blockHash.toHex,
      get=blockHash.toHex
    return false

  return true

proc broadcastNewPayload(cl: CLMocker, payload: ExecutionPayloadV1): Result[PayloadStatusV1, string] =
  let res = cl.client.newPayloadV1(payload)
  return res

proc broadcastNextNewPayload(cl: CLMocker): bool =
  let res = cl.broadcastNewPayload(cl.latestPayloadBuilt)
  if res.isErr:
    error "CLMocker: broadcastNewPayload Error", msg=res.error
    return false

  let s = res.get()
  if s.status == PayloadExecutionStatus.valid:
    # The client is synced and the payload was immediately validated
    # https://github.com/ethereum/execution-apis/blob/main/src/engine/specification.md:
    # - If validation succeeds, the response MUST contain {status: VALID, latestValidHash: payload.blockHash}
    let blockHash = cl.latestPayloadBuilt.blockHash
    if s.latestValidHash.isNone:
      error "CLMocker: NewPayload returned VALID status with nil LatestValidHash",
        expected=blockHash.toHex
      return false

    let latestValidHash = s.latestValidHash.get()
    if latestValidHash != BlockHash(blockHash):
      error "CLMocker: NewPayload returned VALID status with incorrect LatestValidHash",
        get=latestValidHash.toHex, expected=blockHash.toHex
      return false

  elif s.status == PayloadExecutionStatus.accepted:
    # The client is not synced but the payload was accepted
    # https://github.com/ethereum/execution-apis/blob/main/src/engine/specification.md:
    # - {status: ACCEPTED, latestValidHash: null, validationError: null} if the following conditions are met:
    # the blockHash of the payload is valid
    # the payload doesn't extend the canonical chain
    # the payload hasn't been fully validated.
    let nullHash = BlockHash Hash256().data
    let latestValidHash = s.latestValidHash.get(nullHash)
    if s.latestValidHash.isSome and latestValidHash != nullHash:
      error "CLMocker: NewPayload returned ACCEPTED status with incorrect LatestValidHash",
        hash=latestValidHash.toHex
      return false

  else:
    error "CLMocker: broadcastNewPayload Response",
      status=s.status
    return false

  cl.latestExecutedPayload = cl.latestPayloadBuilt
  let number = uint64 cl.latestPayloadBuilt.blockNumber
  cl.executedPayloadHistory[number] = cl.latestPayloadBuilt
  return true

proc broadcastForkchoiceUpdated*(cl: CLMocker,
      update: ForkchoiceStateV1): Result[ForkchoiceUpdatedResponse, string] =
  let res = cl.client.forkchoiceUpdatedV1(update)
  return res

proc broadcastLatestForkchoice(cl: CLMocker): bool =
  let res = cl.broadcastForkchoiceUpdated(cl.latestForkchoice)
  if res.isErr:
    error "CLMocker: broadcastForkchoiceUpdated Error", msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "CLMocker: broadcastForkchoiceUpdated Response",
      status=s.payloadStatus.status
    return false

  return true

proc produceSingleBlock*(cl: CLMocker, cb: BlockProcessCallbacks): bool {.gcsafe.} =
  doAssert(cl.ttdReached)

  if not cl.pickNextPayloadProducer():
    return false

  if cb.onPayloadProducerSelected != nil:
    if not cb.onPayloadProducerSelected():
      return false

  if not cl.getNextPayloadID():
    return false

  if cb.onGetPayloadID != nil:
    if not cb.onGetPayloadID():
      return false

  # Give the client a delay between getting the payload ID and actually retrieving the payload
  #time.Sleep(PayloadProductionClientDelay)

  if not cl.getNextPayload():
    return false

  if cb.onGetPayload != nil:
    if not cb.onGetPayload():
      return false

  if not cl.broadcastNextNewPayload():
    return false

  if cb.onNewPayloadBroadcast != nil:
    if not cb.onNewPayloadBroadcast():
      return false

  # Broadcast forkchoice updated with new HeadBlock to all clients
  let blockHash = cl.latestPayloadBuilt.blockHash
  cl.latestForkchoice.headBlockHash = blockHash
  if not cl.broadcastLatestForkchoice():
    return false

  if cb.onHeadBlockForkchoiceBroadcast != nil:
    if not cb.onHeadBlockForkchoiceBroadcast():
      return false

  # Broadcast forkchoice updated with new SafeBlock to all clients
  cl.latestForkchoice.safeBlockHash = blockHash
  if not cl.broadcastLatestForkchoice():
    return false

  if cb.onSafeBlockForkchoiceBroadcast != nil:
    if not cb.onSafeBlockForkchoiceBroadcast():
      return false

  # Broadcast forkchoice updated with new FinalizedBlock to all clients
  cl.latestForkchoice.finalizedBlockHash = blockHash
  if not cl.broadcastLatestForkchoice():
    return false

  # Save the number of the first PoS block
  if cl.firstPoSBlockNumber.isNone:
    let number = cl.latestFinalizedHeader.blockNumber.truncate(uint64) + 1
    cl.firstPoSBlockNumber = some(number)

  # Save the header of the latest block in the PoS chain
  cl.latestFinalizedNumber = cl.latestFinalizedNumber + 1

  # Check if any of the clients accepted the new payload
  var newHeader: common.BlockHeader
  let res = cl.client.headerByNumber(cl.latestFinalizedNumber, newHeader)
  if res.isErr:
    error "CLMock ProduceSingleBlock", msg=res.error
    return false

  let newHash = BlockHash newHeader.blockHash.data
  if newHash != cl.latestPayloadBuilt.blockHash:
    error "CLMocker: None of the clients accepted the newly constructed payload",
      hash=newHash.toHex
    return false

  cl.latestFinalizedHeader = newHeader

  if cb.onFinalizedBlockForkchoiceBroadcast != nil:
    if not cb.onFinalizedBlockForkchoiceBroadcast():
      return false

  return true

# Loop produce PoS blocks by using the Engine API
proc produceBlocks*(cl: CLMocker, blockCount: int, cb: BlockProcessCallbacks): bool {.gcsafe.} =
  # Produce requested amount of blocks
  for i in 0..<blockCount:
    if not cl.produceSingleBlock(cb):
      return false
  return true

# Check whether a block number is a PoS block
proc isBlockPoS*(cl: CLMocker, bn: common.BlockNumber): bool =
  if cl.firstPoSBlockNumber.isNone:
    return false

  let number = cl.firstPoSBlockNumber.get()
  let bn = bn.truncate(uint64)
  if number > bn:
    return false

  return true

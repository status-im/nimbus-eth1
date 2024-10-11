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
  std/[tables],
  chronicles,
  stew/[byteutils],
  eth/common, chronos,
  json_rpc/rpcclient,
  web3/execution_types,
  ../../../nimbus/beacon/web3_eth_conv,
  ../../../nimbus/beacon/payload_conv,
  ../../../nimbus/[constants],
  ../../../nimbus/common as nimbus_common,
  ./client_pool,
  ./engine_env,
  ./engine_client,
  ./types

import web3/engine_api_types except Hash256  # conflict with the one from eth/common

# Consensus Layer Client Mock used to sync the Execution Clients once the TTD has been reached
type
  CLMocker* = ref object
    com: CommonRef

    # Number of required slots before a block which was set as Head moves to `safe` and `finalized` respectively
    slotsToSafe*     : int
    slotsToFinalized*: int
    safeSlotsToImportOptimistically*: int

    # Wait time before attempting to get the payload
    payloadProductionClientDelay*: int

    # Block production related
    blockTimestampIncrement*: Opt[int]

    # Block Production State
    clients                 : ClientPool
    nextBlockProducer*      : EngineEnv
    nextFeeRecipient*       : EthAddress
    nextPayloadID*          : PayloadID
    currentPayloadNumber*   : uint64

    # Chain History
    headerHistory           : Table[uint64, common.BlockHeader]

    # Payload ID History
    payloadIDHistory        : Table[string, PayloadID]

    # PoS Chain History Information
    prevRandaoHistory*      : Table[uint64, common.Hash256]
    executedPayloadHistory* : Table[uint64, ExecutionPayload]
    headHashHistory         : seq[BlockHash]

    # Latest broadcasted data using the PoS Engine API
    latestHeadNumber*       : uint64
    latestHeader*           : common.BlockHeader
    latestPayloadBuilt*     : ExecutionPayload
    latestBlockValue*       : Opt[UInt256]
    latestBlobsBundle*      : Opt[BlobsBundleV1]
    latestShouldOverrideBuilder*: Opt[bool]
    latestPayloadAttributes*: PayloadAttributes
    latestExecutedPayload*  : ExecutableData
    latestForkchoice*       : ForkchoiceStateV1
    latestExecutionRequests*: Opt[array[3, seq[byte]]]

    # Merge related
    firstPoSBlockNumber*      : Opt[uint64]
    ttdReached*               : bool
    transitionPayloadTimestamp: Opt[int]
    chainTotalDifficulty      : UInt256

    # Shanghai related
    nextWithdrawals*          : Opt[seq[WithdrawalV1]]

  BlockProcessCallbacks* = object
    onPayloadProducerSelected* : proc(): bool {.gcsafe.}
    onPayloadAttributesGenerated* : proc(): bool {.gcsafe.}
    onRequestNextPayload*      : proc(): bool {.gcsafe.}
    onGetPayload*              : proc(): bool {.gcsafe.}
    onNewPayloadBroadcast*     : proc(): bool {.gcsafe.}
    onForkchoiceBroadcast*     : proc(): bool {.gcsafe.}
    onSafeBlockChange *        : proc(): bool {.gcsafe.}
    onFinalizedBlockChange*    : proc(): bool {.gcsafe.}


proc collectBlobHashes(list: openArray[Web3Tx]): seq[common.Hash256] =
  for w3tx in list:
    let tx = ethTx(w3tx)
    for h in tx.versionedHashes:
      result.add h

func latestExecutableData*(cl: CLMocker): ExecutableData =
  ExecutableData(
    basePayload: cl.latestPayloadBuilt,
    beaconRoot : ethHash cl.latestPayloadAttributes.parentBeaconBlockRoot,
    attr       : cl.latestPayloadAttributes,
    versionedHashes: Opt.some(collectBlobHashes(cl.latestPayloadBuilt.transactions)),
    executionRequests: cl.latestExecutionRequests,
  )

func latestPayloadNumber*(h: Table[uint64, ExecutionPayload]): uint64 =
  result = 0'u64
  for n, _ in h:
    if n > result:
      result = n

func latestWithdrawalsIndex*(h: Table[uint64, ExecutionPayload]): uint64 =
  result = 0'u64
  for n, p in h:
    if p.withdrawals.isNone:
      continue
    let wds = p.withdrawals.get
    for w in wds:
      if w.index.uint64 > result:
        result = w.index.uint64

func client(cl: CLMocker): RpcClient =
  cl.clients.first.client

proc init(cl: CLMocker, eng: EngineEnv, com: CommonRef) =
  cl.clients = ClientPool()
  cl.clients.add eng
  cl.com = com
  cl.slotsToSafe = 1
  cl.slotsToFinalized = 2
  cl.payloadProductionClientDelay = 0
  cl.headerHistory[0] = com.genesisHeader()

proc newClMocker*(eng: EngineEnv, com: CommonRef): CLMocker =
  new result
  result.init(eng, com)

proc addEngine*(cl: CLMocker, eng: EngineEnv) =
  cl.clients.add eng
  echo "CLMocker: Adding engine client ", eng.ID()

proc removeEngine*(cl: CLMocker, eng: EngineEnv) =
  cl.clients.remove eng
  echo "CLMocker: Removing engine client ", eng.ID()

proc waitForTTD*(cl: CLMocker): Future[bool] {.async.} =
  let ttd = cl.com.ttd()
  doAssert(ttd.isSome)
  let (header, waitRes) = await cl.client.waitForTTD(ttd.get)
  if not waitRes:
    error "CLMocker: timeout while waiting for TTD"
    return false

  echo "CLMocker: TTD has been reached at block ", header.number

  cl.latestHeader = header
  cl.headerHistory[header.number] = header
  cl.ttdReached = true

  let headerHash = BlockHash(common.blockHash(cl.latestHeader).data)
  if cl.slotsToSafe == 0:
    cl.latestForkchoice.safeBlockHash = headerHash

  if cl.slotsToFinalized == 0:
    cl.latestForkchoice.finalizedBlockHash = headerHash

  # Reset transition values
  cl.latestHeadNumber = cl.latestHeader.number
  cl.headHashHistory = @[]
  cl.firstPoSBlockNumber = Opt.none(uint64)

  # Prepare initial forkchoice, to be sent to the transition payload producer
  cl.latestForkchoice = ForkchoiceStateV1()
  cl.latestForkchoice.headBlockHash = headerHash

  let res = cl.client.forkchoiceUpdatedV1(cl.latestForkchoice)
  if res.isErr:
    error "waitForTTD: forkchoiceUpdated error", msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "waitForTTD: forkchoiceUpdated response unexpected",
      expect = PayloadExecutionStatus.valid,
      get = s.payloadStatus.status
    return false

  return true

# Check whether a block number is a PoS block
proc isBlockPoS*(cl: CLMocker, bn: common.BlockNumber): bool =
  if cl.firstPoSBlockNumber.isNone:
    return false

  let number = cl.firstPoSBlockNumber.get()
  if number > bn:
    return false

  return true

proc addPayloadID*(cl: CLMocker, eng: EngineEnv, newPayloadID: PayloadID): bool =
  # Check if payload ID has been used before
  var zeroPayloadID: PayloadID
  if cl.payloadIDHistory.getOrDefault(eng.ID(), zeroPayloadID) == newPayloadID:
    error "reused payload ID", ID = newPayloadID.toHex
    return false

  # Add payload ID to history
  cl.payloadIDHistory[eng.ID()] = newPayloadID
  info "CLMocker: Added payload for client",
    ID=newPayloadID.toHex, ID=eng.ID()
  return true

# Return the per-block timestamp value increment
func getTimestampIncrement(cl: CLMocker): EthTime =
  EthTime cl.blockTimestampIncrement.get(1)

# Returns the timestamp value to be included in the next payload attributes
func getNextBlockTimestamp(cl: CLMocker): EthTime =
  if cl.firstPoSBlockNumber.isNone and cl.transitionPayloadTimestamp.isSome:
    # We are producing the transition payload and there's a value specified
    # for this specific payload
    return EthTime cl.transitionPayloadTimestamp.get
  return cl.latestHeader.timestamp + cl.getTimestampIncrement()

func setNextWithdrawals(cl: CLMocker, nextWithdrawals: Opt[seq[WithdrawalV1]]) =
  cl.nextWithdrawals = nextWithdrawals

func isShanghai(cl: CLMocker, timestamp: Quantity): bool =
  let ts = EthTime(timestamp.uint64)
  cl.com.isShanghaiOrLater(ts)

func isCancun(cl: CLMocker, timestamp: Quantity): bool =
  let ts = EthTime(timestamp.uint64)
  cl.com.isCancunOrLater(ts)

# Picks the next payload producer from the set of clients registered
proc pickNextPayloadProducer(cl: CLMocker): bool =
  doAssert cl.clients.len != 0

  for i in 0 ..< cl.clients.len:
    # Get a client to generate the payload
    let id = (cl.latestHeadNumber.int + i) mod cl.clients.len
    cl.nextBlockProducer = cl.clients[id]

    echo "CLMocker: Selected payload producer: ", cl.nextBlockProducer.ID()

    # Get latest header. Number and hash must coincide with our view of the chain,
    # and only then we can build on top of this client's chain
    let res = cl.nextBlockProducer.client.latestHeader()
    if res.isErr:
      error "CLMocker: Could not get latest block header while selecting client for payload production",
        msg=res.error
      return false

    let latestHeader = res.get
    let lastBlockHash = latestHeader.blockHash
    if cl.latestHeader.blockHash != lastBlockHash or
       cl.latestHeadNumber != latestHeader.number:
      # Selected client latest block hash does not match canonical chain, try again
      cl.nextBlockProducer = nil
      continue
    else:
      break

  doAssert cl.nextBlockProducer != nil
  return true

proc generatePayloadAttributes(cl: CLMocker) =
  # Generate a random value for the PrevRandao field
  let nextPrevRandao = common.Hash256.randomBytes()
  let timestamp = Quantity cl.getNextBlockTimestamp.uint64
  cl.latestPayloadAttributes = PayloadAttributes(
    timestamp:             timestamp,
    prevRandao:            FixedBytes[32] nextPrevRandao.data,
    suggestedFeeRecipient: Address cl.nextFeeRecipient,
  )

  if cl.isShanghai(timestamp):
    cl.latestPayloadAttributes.withdrawals = cl.nextWithdrawals

  if cl.isCancun(timestamp):
    # Write a deterministic hash based on the block number
    let beaconRoot = timestampToBeaconRoot(timestamp)
    cl.latestPayloadAttributes.parentBeaconBlockRoot = Opt.some(beaconRoot)

  # Save random value
  let number = cl.latestHeader.number + 1
  cl.prevRandaoHistory[number] = nextPrevRandao

proc requestNextPayload(cl: CLMocker): bool =
  let version = cl.latestPayloadAttributes.version
  let client = cl.nextBlockProducer.client
  let res = client.forkchoiceUpdated(version, cl.latestForkchoice, Opt.some(cl.latestPayloadAttributes))
  if res.isErr:
    error "CLMocker: Could not send forkchoiceUpdated", version=version, msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "CLMocker: Unexpected forkchoiceUpdated Response from Payload builder",
      status=s.payloadStatus.status
    return false

  if s.payloadStatus.latestValidHash.isNone or s.payloadStatus.latestValidHash.get != cl.latestForkchoice.headBlockHash:
    error "CLMocker: Unexpected forkchoiceUpdated LatestValidHash Response from Payload builder",
      latest=s.payloadStatus.latestValidHash,
      head=cl.latestForkchoice.headBlockHash
    return false

  doAssert s.payLoadID.isSome
  cl.nextPayloadID = s.payloadID.get()
  return true

proc getPayload(cl: CLMocker, payloadId: PayloadID): Result[GetPayloadResponse, string] =
  let ts = cl.latestPayloadAttributes.timestamp
  let client = cl.nextBlockProducer.client
  if cl.isCancun(ts):
    client.getPayload(payloadId, Version.V3)
  elif cl.isShanghai(ts):
    client.getPayload(payloadId, Version.V2)
  else:
    client.getPayload(payloadId, Version.V1)

proc getNextPayload(cl: CLMocker): bool =
  let res = cl.getPayload(cl.nextPayloadID)
  if res.isErr:
    error "CLMocker: Could not getPayload",
      payloadID=toHex(cl.nextPayloadID)
    return false

  let x = res.get()
  cl.latestPayloadBuilt = x.executionPayload
  cl.latestBlockValue = x.blockValue
  cl.latestBlobsBundle = x.blobsBundle
  cl.latestShouldOverrideBuilder = x.shouldOverrideBuilder
  cl.latestExecutionRequests = x.executionRequests

  let beaconRoot = ethHash cl.latestPayloadAttributes.parentBeaconblockRoot
  let requestsHash = calcRequestsHash(x.executionRequests)
  let header = blockHeader(cl.latestPayloadBuilt, beaconRoot = beaconRoot, requestsHash)
  let blockHash = w3Hash header.blockHash
  if blockHash != cl.latestPayloadBuilt.blockHash:
    error "CLMocker: getNextPayload blockHash mismatch",
      expected=cl.latestPayloadBuilt.blockHash,
      get=blockHash.toHex
    return false

  if cl.latestPayloadBuilt.timestamp != cl.latestPayloadAttributes.timestamp:
    error "CLMocker: Incorrect Timestamp on payload built",
      expect=cl.latestPayloadBuilt.timestamp.uint64,
      get=cl.latestPayloadAttributes.timestamp.uint64
    return false

  if cl.latestPayloadBuilt.feeRecipient != cl.latestPayloadAttributes.suggestedFeeRecipient:
    error "CLMocker: Incorrect SuggestedFeeRecipient on payload built",
      expect=cl.latestPayloadBuilt.feeRecipient,
      get=cl.latestPayloadAttributes.suggestedFeeRecipient
    return false

  if cl.latestPayloadBuilt.prevRandao != cl.latestPayloadAttributes.prevRandao:
    error "CLMocker: Incorrect PrevRandao on payload built",
      expect=cl.latestPayloadBuilt.prevRandao,
      get=cl.latestPayloadAttributes.prevRandao
    return false

  if cl.latestPayloadBuilt.parentHash != BlockHash cl.latestHeader.blockHash.data:
    error "CLMocker: Incorrect ParentHash on payload built",
      expect=cl.latestPayloadBuilt.parentHash,
      get=cl.latestHeader.blockHash
    return false

  if cl.latestPayloadBuilt.blockNumber.uint64 != cl.latestHeader.number + 1'u64:
    error "CLMocker: Incorrect Number on payload built",
      expect=cl.latestPayloadBuilt.blockNumber.uint64,
      get=cl.latestHeader.number+1'u64
    return false

  return true

func versionedHashes(payload: ExecutionPayload): seq[Web3Hash] =
  result = newSeqOfCap[BlockHash](payload.transactions.len)
  for x in payload.transactions:
    let tx = rlp.decode(distinctBase(x), Transaction)
    for vs in tx.versionedHashes:
      result.add w3Hash vs

proc broadcastNewPayload(cl: CLMocker,
                         eng: EngineEnv,
                         payload: ExecutableData): Result[PayloadStatusV1, string] =
  let version = eng.version(payload.basePayload.timestamp)
  case version
  of Version.V1: return eng.client.newPayloadV1(payload.basePayload.V1)
  of Version.V2: return eng.client.newPayloadV2(payload.basePayload.V2)
  of Version.V3: return eng.client.newPayloadV3(payload.basePayload.V3,
    versionedHashes(payload.basePayload),
    cl.latestPayloadAttributes.parentBeaconBlockRoot.get)
  of Version.V4:    
    return eng.client.newPayloadV4(payload.basePayload.V3,
      versionedHashes(payload.basePayload),
      cl.latestPayloadAttributes.parentBeaconBlockRoot.get,
      payload.executionRequests.get)

proc broadcastNextNewPayload(cl: CLMocker): bool =
  for eng in cl.clients:
    let res = cl.broadcastNewPayload(eng, cl.latestExecutedPayload)
    if res.isErr:
      error "CLMocker: broadcastNewPayload Error", msg=res.error
      return false

    let s = res.get()
    echo "CLMocker: Executed payload on ", eng.ID(),
      " ", s.status, " ", s.latestValidHash

    if s.status == PayloadExecutionStatus.valid:
      # The client is synced and the payload was immediately validated
      # https:#github.com/ethereum/execution-apis/blob/main/src/engine/specification.md:
      # - If validation succeeds, the response MUST contain {status: VALID, latestValidHash: payload.blockHash}
      let blockHash = cl.latestPayloadBuilt.blockHash
      if s.latestValidHash.isNone:
        error "CLMocker: NewPayload returned VALID status with nil LatestValidHash",
          expected=blockHash.toHex
        return false

      let latestValidHash = s.latestValidHash.get()
      if latestValidHash != blockHash:
        error "CLMocker: NewPayload returned VALID status with incorrect LatestValidHash",
          get=latestValidHash.toHex, expected=blockHash.toHex
        return false

    elif s.status == PayloadExecutionStatus.accepted:
      # The client is not synced but the payload was accepted
      # https:#github.com/ethereum/execution-apis/blob/main/src/engine/specification.md:
      # - {status: ACCEPTED, latestValidHash: null, validationError: null} if the following conditions are met:
      # the blockHash of the payload is valid
      # the payload doesn't extend the canonical chain
      # the payload hasn't been fully validated.
      let nullHash = w3Hash default(common.Hash256)
      let latestValidHash = s.latestValidHash.get(nullHash)
      if s.latestValidHash.isSome and latestValidHash != nullHash:
        error "CLMocker: NewPayload returned ACCEPTED status with incorrect LatestValidHash",
          hash=latestValidHash.toHex
        return false

    else:
      error "CLMocker: broadcastNewPayload Response",
        status=s.status,
        msg=s.validationError.get("NO MSG")
      return false

  # warning: although latestExecutedPayload is taken from
  # latestPayloadBuilt, but during the next round, it can be different

  cl.latestExecutedPayload = cl.latestExecutableData()
  let number = uint64 cl.latestPayloadBuilt.blockNumber
  cl.executedPayloadHistory[number] = cl.latestPayloadBuilt
  return true

proc broadcastForkchoiceUpdated(cl: CLMocker,
                                eng: EngineEnv,
                                version: Version,
                                update: ForkchoiceStateV1):
                                  Result[ForkchoiceUpdatedResponse, string] =
  eng.client.forkchoiceUpdated(version, update, Opt.none(PayloadAttributes))

proc broadcastForkchoiceUpdated*(cl: CLMocker,
                                 version: Version,
                                 update: ForkchoiceStateV1): bool =
  for eng in cl.clients:
    let res = cl.broadcastForkchoiceUpdated(eng, version, update)
    if res.isErr:
      error "CLMocker: broadcastForkchoiceUpdated Error", msg=res.error
      return false

    let s = res.get()
    if s.payloadStatus.status != PayloadExecutionStatus.valid:
      error "CLMocker: broadcastForkchoiceUpdated Response",
        status=s.payloadStatus.status,
        msg=s.payloadStatus.validationError.get("NO MSG")
      return false

    if s.payloadStatus.latestValidHash.get != cl.latestForkchoice.headBlockHash:
      error "CLMocker: Incorrect LatestValidHash from ForkchoiceUpdated",
        get=s.payloadStatus.latestValidHash.get.toHex,
        expect=cl.latestForkchoice.headBlockHash.toHex
      return false

    if s.payloadStatus.validationError.isSome:
      error "CLMocker: Expected empty validationError",
        msg=s.payloadStatus.validationError.get
      return false

    if s.payloadID.isSome:
      error "CLMocker: Expected empty PayloadID",
        msg=s.payloadID.get.toHex
      return false

  return true

proc broadcastLatestForkchoice(cl: CLMocker): bool =
  let version = cl.latestExecutedPayload.version
  cl.broadcastForkchoiceUpdated(version, cl.latestForkchoice)

func w3Address(x: int): Web3Address =
  var res: array[20, byte]
  res[^1] = x.byte
  Web3Address(res)

proc makeNextWithdrawals(cl: CLMocker): seq[WithdrawalV1] =
  var
    withdrawalCount = 10
    withdrawalIndex = 0'u64

  if cl.latestPayloadBuilt.withdrawals.isSome:
    let wds = cl.latestPayloadBuilt.withdrawals.get
    for w in wds:
      if w.index.uint64 > withdrawalIndex:
        withdrawalIndex = w.index.uint64

  var
    withdrawals = newSeq[WithdrawalV1](withdrawalCount)

  for i in 0..<withdrawalCount:
    withdrawalIndex += 1
    withdrawals[i] = WithdrawalV1(
      index:          w3Qty withdrawalIndex,
      validatorIndex: Quantity i,
      address:        w3Address i,
      amount:         w3Qty 100'u64,
    )

  return withdrawals

proc produceSingleBlock*(cl: CLMocker, cb: BlockProcessCallbacks): bool {.gcsafe.} =
  doAssert(cl.ttdReached)

  cl.currentPayloadNumber = cl.latestHeader.number + 1'u64
  if not cl.pickNextPayloadProducer():
    return false

  # Check if next withdrawals necessary, test can override this value on
  # `OnPayloadProducerSelected` callback
  if cl.nextWithdrawals.isNone:
    let nw = cl.makeNextWithdrawals()
    cl.setNextWithdrawals(Opt.some(nw))

  if cb.onPayloadProducerSelected != nil:
    if not cb.onPayloadProducerSelected():
      debugEcho "***PAYLOAD PRODUCER SELECTED ERROR***"
      return false

  cl.generatePayloadAttributes()

  if cb.onPayloadAttributesGenerated != nil:
    if not cb.onPayloadAttributesGenerated():
      debugEcho "***ON PAYLOAD ATTRIBUTES ERROR***"
      return false

  if not cl.requestNextPayload():
    return false

  cl.setNextWithdrawals(Opt.none(seq[WithdrawalV1]))

  if cb.onRequestNextPayload != nil:
    if not cb.onRequestNextPayload():
      debugEcho "***ON REQUEST NEXT PAYLOAD ERROR***"
      return false

  # Give the client a delay between getting the payload ID and actually retrieving the payload
  if cl.payloadProductionClientDelay != 0:
    let period = chronos.seconds(cl.payloadProductionClientDelay)
    waitFor sleepAsync(period)

  if not cl.getNextPayload():
    return false

  if cb.onGetPayload != nil:
    if not cb.onGetPayload():
      debugEcho "***ON GET PAYLOAD ERROR***"
      return false

  if not cl.broadcastNextNewPayload():
    debugEcho "***ON BROADCAST NEXT NEW PAYLOAD ERROR***"
    return false

  if cb.onNewPayloadBroadcast != nil:
    if not cb.onNewPayloadBroadcast():
      debugEcho "***ON NEW PAYLOAD BROADCAST ERROR***"
      return false

  # Broadcast forkchoice updated with new HeadBlock to all clients
  let previousForkchoice = cl.latestForkchoice
  cl.headHashHistory.add cl.latestPayloadBuilt.blockHash

  cl.latestForkchoice = ForkchoiceStateV1()
  cl.latestForkchoice.headBlockHash = cl.latestPayloadBuilt.blockHash

  let hhLen = cl.headHashHistory.len
  if hhLen > cl.slotsToSafe:
    cl.latestForkchoice.safeBlockHash = cl.headHashHistory[hhLen - cl.slotsToSafe - 1]

  if hhLen > cl.slotsToFinalized:
    cl.latestForkchoice.finalizedBlockHash = cl.headHashHistory[hhLen - cl.slotsToFinalized - 1]

  if not cl.broadcastLatestForkchoice():
    debugEcho "***ON BROADCAST LATEST FORK CHOICE ERROR***"
    return false

  if cb.onForkchoiceBroadcast != nil:
    if not cb.onForkchoiceBroadcast():
      debugEcho "***ON FORK CHOICE BROADCAST ERROR***"
      return false

  # Broadcast forkchoice updated with new SafeBlock to all clients
  if cb.onSafeBlockChange != nil and cl.latestForkchoice.safeBlockHash != previousForkchoice.safeBlockHash:
    if not cb.onSafeBlockChange():
      debugEcho "***ON SAFE BLOCK CHANGE ERROR***"
      return false

  # Broadcast forkchoice updated with new FinalizedBlock to all clients
  if cb.onFinalizedBlockChange != nil and cl.latestForkchoice.finalizedBlockHash != previousForkchoice.finalizedBlockHash:
    if not cb.onFinalizedBlockChange():
      debugEcho "***ON FINALIZED BLOCK CHANGE ERROR***"
      return false

  # Broadcast forkchoice updated with new FinalizedBlock to all clients
  # Save the number of the first PoS block
  if cl.firstPoSBlockNumber.isNone:
    let number = cl.latestHeader.number + 1
    cl.firstPoSBlockNumber = Opt.some(number)

  # Save the header of the latest block in the PoS chain
  cl.latestHeadNumber = cl.latestHeadNumber + 1

  # Check if any of the clients accepted the new payload
  let res = cl.client.headerByNumber(cl.latestHeadNumber)
  if res.isErr:
    error "CLMock ProduceSingleBlock", msg=res.error
    return false

  let newHeader = res.get
  let newHash = w3Hash newHeader.blockHash
  if newHash != cl.latestPayloadBuilt.blockHash:
    error "CLMocker: None of the clients accepted the newly constructed payload",
      hash=newHash.toHex
    return false

  # Check that the new finalized header has the correct properties
  # ommersHash == 0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347
  if newHeader.ommersHash != EMPTY_UNCLE_HASH:
    error "CLMocker: Client produced a new header with incorrect ommersHash", ommersHash = newHeader.ommersHash
    return false

  # difficulty == 0
  if newHeader.difficulty != 0.u256:
    error "CLMocker: Client produced a new header with incorrect difficulty", difficulty = newHeader.difficulty
    return false

  # mixHash == prevRandao
  if newHeader.mixHash != Bytes32 cl.prevRandaoHistory[cl.latestHeadNumber]:
    error "CLMocker: Client produced a new header with incorrect mixHash",
      get = newHeader.mixHash,
      expect = cl.prevRandaoHistory[cl.latestHeadNumber]
    return false

  # nonce == 0x0000000000000000
  if newHeader.nonce != default(BlockNonce):
    error "CLMocker: Client produced a new header with incorrect nonce",
      nonce = newHeader.nonce.toHex
    return false

  if newHeader.extraData.len > 32:
    error "CLMocker: Client produced a new header with incorrect extraData (len > 32)",
      len = newHeader.extraData.len
    return false

  cl.latestHeader = newHeader
  cl.headerHistory[cl.latestHeadNumber] = cl.latestHeader

  echo "CLMocker: New block produced: number=", newHeader.number,
    " hash=", newHeader.blockHash

  return true

# Loop produce PoS blocks by using the Engine API
proc produceBlocks*(cl: CLMocker, blockCount: int, cb: BlockProcessCallbacks): bool {.gcsafe.} =
  # Produce requested amount of blocks
  for i in 0..<blockCount:
    if not cl.produceSingleBlock(cb):
      return false
  return true

proc posBlockNumber*(cl: CLMocker): uint64 =
  cl.firstPoSBlockNumber.get(0'u64)

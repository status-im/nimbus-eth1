import
  std/tables,
  stew/byteutils,
  chronicles,
  eth/common,
  nimcrypto/sysrand,
  chronos,
  ".."/[test_env, helper, types],
  ../../../nimbus/transaction,
  ../../../nimbus/rpc/rpc_types,
  ../../../nimbus/beacon/web3_eth_conv,
  ../../../nimbus/beacon/execution_types

type
  EngineSpec* = ref object of BaseSpec
    exec*: proc(t: TestEnv): bool
    ttd*: int64
    chainFile*: string
    slotsToFinalized*: int
    slotsToSafe*: int

const
  prevRandaoContractAddr = hexToByteArray[20]("0000000000000000000000000000000000000316")

template testNP(res, cond: untyped, validHash = none(common.Hash256)) =
  testCond res.isOk
  let s = res.get()
  testCond s.status == PayloadExecutionStatus.cond:
    error "Unexpected NewPayload status", expect=PayloadExecutionStatus.cond, get=s.status
  testCond s.latestValidHash == validHash:
    error "Unexpected NewPayload latestValidHash", expect=validHash, get=s.latestValidHash

template testNPEither(res, cond: untyped, validHash = none(common.Hash256)) =
  testCond res.isOk
  let s = res.get()
  testCond s.status in cond:
    error "Unexpected NewPayload status", expect=cond, get=s.status
  testCond s.latestValidHash == validHash:
    error "Unexpected NewPayload latestValidHash", expect=validHash, get=s.latestValidHash

template testLatestHeader(client: untyped, expectedHash: Web3Hash) =
  var lastHeader: common.BlockHeader
  var hRes = client.latestHeader(lastHeader)
  testCond hRes.isOk:
    error "unable to get latest header", msg=hRes.error

  let lastHash = w3Hash lastHeader.blockHash
  # Latest block header available via Eth RPC should not have changed at this point
  testCond lastHash == expectedHash:
    error "latest block header incorrect",
      expect = expectedHash,
      get = lastHash

#proc sendTx(t: TestEnv, recipient: EthAddress, val: UInt256, data: openArray[byte] = []): bool =
#  t.tx = t.makeTx(recipient, val, data)
#  let rr = t.rpcClient.sendTransaction(t.tx)
#  if rr.isErr:
#    error "Unable to send transaction", msg=rr.error
#    return false
#  return true
#
#proc sendTx(t: TestEnv, val: UInt256): bool =
#  t.sendTx(prevRandaoContractAddr, val)

# Invalid Terminal Block in ForkchoiceUpdated:
# Client must reject ForkchoiceUpdated directives if the referenced HeadBlockHash does not meet the TTD requirement.
proc invalidTerminalBlockForkchoiceUpdated*(t: TestEnv): bool =
  let
    gHash = w3Hash t.gHeader.blockHash
    forkchoiceState = ForkchoiceStateV1(
      headBlockHash:      gHash,
      safeBlockHash:      gHash,
      finalizedBlockHash: gHash,
    )

  let res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceState)
  # Execution specification:
  # {payloadStatus: {status: INVALID, latestValidHash=0x00..00}, payloadId: null}
  # either obtained from the Payload validation process or as a result of
  # validating a PoW block referenced by forkchoiceState.headBlockHash

  testFCU(res, invalid, some(common.Hash256()))
  # ValidationError is not validated since it can be either null or a string message

  # Check that PoW chain progresses
  testCond t.verifyPoWProgress(t.gHeader.blockHash)
  return true

#[
# Invalid GetPayload Under PoW: Client must reject GetPayload directives under PoW.
proc invalidGetPayloadUnderPoW(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # We start in PoW and try to get an invalid Payload, which should produce an error but nothing should be disrupted.
  let id = PayloadID [1.byte, 2,3,4,5,6,7,8]
  let res = t.rpcClient.getPayloadV1(id)
  testCond res.isErr

  # Check that PoW chain progresses
  testCond t.verifyPoWProgress(t.gHeader.blockHash)

# Invalid Terminal Block in NewPayload:
# Client must reject NewPayload directives if the referenced ParentHash does not meet the TTD requirement.
proc invalidTerminalBlockNewPayload(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let gBlock = t.gHeader
  let payload = ExecutableData(
    parentHash:   gBlock.blockHash,
    stateRoot:    gBlock.stateRoot,
    receiptsRoot: EMPTY_ROOT_HASH,
    number:       1,
    gasLimit:     gBlock.gasLimit,
    gasUsed:      0,
    timestamp:    gBlock.timestamp + 1.seconds,
    baseFeePerGas:gBlock.baseFee
  )
  let hashedPayload = customizePayload(payload, CustomPayload())
  let res = t.rpcClient.newPayloadV1(hashedPayload)

  # Execution specification:
  # {status: INVALID, latestValidHash=0x00..00}
  # if terminal block conditions are not satisfied
  testNP(res, invalid, some(common.Hash256()))

  # Check that PoW chain progresses
  testCond t.verifyPoWProgress(t.gHeader.blockHash)

proc unknownHeadBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  var randomHash: common.Hash256
  testCond randomBytes(randomHash.data) == 32

  let clMock = t.clMock
  let forkchoiceStateUnknownHeadHash = ForkchoiceStateV1(
    headBlockHash:      BlockHash randomHash.data,
    safeBlockHash:      clMock.latestForkchoice.finalizedBlockHash,
    finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash,
  )

  var res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceStateUnknownHeadHash)
  testCond res.isOk

  let s = res.get()
  # Execution specification::
  # - {payloadStatus: {status: SYNCING, latestValidHash: null, validationError: null}, payloadId: null}
  #   if forkchoiceState.headBlockHash references an unknown payload or a payload that can't be validated
  #   because requisite data for the validation is missing
  testCond s.payloadStatus.status == PayloadExecutionStatus.syncing

  # Test again using PayloadAttributes, should also return SYNCING and no PayloadID
  let timestamp = uint64 clMock.latestExecutedPayload.timestamp
  let payloadAttr = PayloadAttributesV1(
    timestamp: Quantity(timestamp + 1)
  )

  res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceStateUnknownHeadHash, some(payloadAttr))
  testCond res.isOk
  testCond s.payloadStatus.status == PayloadExecutionStatus.syncing
  testCond s.payloadId.isNone

proc unknownSafeBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  let produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been broadcast
    onNewPayloadBroadcast: proc(): bool =
      # Generate a random SafeBlock hash
      var randomSafeBlockHash: common.Hash256
      doAssert randomBytes(randomSafeBlockHash.data) == 32

      # Send forkchoiceUpdated with random SafeBlockHash
      let forkchoiceStateUnknownSafeHash = ForkchoiceStateV1(
        headBlockHash:      clMock.latestExecutedPayload.blockHash,
        safeBlockHash:      BlockHash randomSafeBlockHash.data,
        finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash,
      )
      # Execution specification:
      # - This value MUST be either equal to or an ancestor of headBlockHash
      let res = client.forkchoiceUpdatedV1(forkchoiceStateUnknownSafeHash)
      return res.isErr
  ))

  testCond produceSingleBlockRes

proc unknownFinalizedBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  let produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been broadcast
    onNewPayloadBroadcast: proc(): bool =
      # Generate a random SafeBlock hash
      var randomFinalBlockHash: common.Hash256
      doAssert randomBytes(randomFinalBlockHash.data) == 32

      # Send forkchoiceUpdated with random SafeBlockHash
      let forkchoiceStateUnknownFinalizedHash = ForkchoiceStateV1(
        headBlockHash:      clMock.latestExecutedPayload.blockHash,
        safeBlockHash:      clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: BlockHash randomFinalBlockHash.data,
      )
      # Execution specification:
      # - This value MUST be either equal to or an ancestor of headBlockHash
      var res = client.forkchoiceUpdatedV1(forkchoiceStateUnknownFinalizedHash)
      if res.isOk:
        return false

      # Test again using PayloadAttributes, should also return INVALID and no PayloadID
      let timestamp = uint64 clMock.latestExecutedPayload.timestamp
      let payloadAttr = PayloadAttributesV1(
        timestamp:  Quantity(timestamp + 1)
      )
      res = client.forkchoiceUpdatedV1(forkchoiceStateUnknownFinalizedHash, some(payloadAttr))
      return res.isErr
  ))

  testCond produceSingleBlockRes

# Send an inconsistent ForkchoiceState with a known payload that belongs to a side chain as head, safe or finalized.
type
  Inconsistency {.pure.} = enum
    Head
    Safe
    Finalized

  PayloadList = ref object
    canonicalPayloads  : seq[ExecutableData]
    alternativePayloads: seq[ExecutableData]

template inconsistentForkchoiceStateGen(procname: untyped, inconsistency: Inconsistency) =
  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    # Wait until TTD is reached by this client
    let ok = waitFor t.clMock.waitForTTD()
    testCond ok

    var pList = PayloadList()
    let clMock = t.clMock
    let client = t.rpcClient

    # Produce blocks before starting the test
    let produceBlockRes = clMock.produceBlocks(3, BlockProcessCallbacks(
      onGetPayload: proc(): bool =
        # Generate and send an alternative side chain
        var customData = CustomPayload(
          extraData: some(@[0x01.byte])
        )

        if pList.alternativePayloads.len > 0:
          customData.parentHash = some(pList.alternativePayloads[^1].blockHash)

        let executableData = toExecutableData(clMock.latestPayloadBuilt)
        let alternativePayload = customizePayload(executableData, customData)
        pList.alternativePayloads.add(alternativePayload.toExecutableData)

        let latestCanonicalPayload = toExecutableData(clMock.latestPayloadBuilt)
        pList.canonicalPayloads.add(latestCanonicalPayload)

        # Send the alternative payload
        let res = client.newPayloadV1(alternativePayload)
        if res.isErr:
          return false

        let s = res.get()
        s.status == PayloadExecutionStatus.valid or s.status == PayloadExecutionStatus.accepted
    ))

    testCond produceBlockRes

    # Send the invalid ForkchoiceStates
    let len = pList.alternativePayloads.len
    var inconsistentFcU = ForkchoiceStateV1(
      headBlockHash:      Web3BlockHash pList.canonicalPayloads[len-1].blockHash.data,
      safeBlockHash:      Web3BlockHash pList.canonicalPayloads[len-2].blockHash.data,
      finalizedBlockHash: Web3BlockHash pList.canonicalPayloads[len-3].blockHash.data,
    )

    when inconsistency == Inconsistency.Head:
      inconsistentFcU.headBlockHash = Web3BlockHash pList.alternativePayloads[len-1].blockHash.data
    elif inconsistency == Inconsistency.Safe:
      inconsistentFcU.safeBlockHash = Web3BlockHash pList.alternativePayloads[len-2].blockHash.data
    else:
      inconsistentFcU.finalizedBlockHash = Web3BlockHash pList.alternativePayloads[len-3].blockHash.data

    var r = client.forkchoiceUpdatedV1(inconsistentFcU)
    testCond r.isErr

    # Return to the canonical chain
    r = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
    testCond r.isOk
    let s = r.get()
    testCond s.payloadStatus.status == PayloadExecutionStatus.valid

inconsistentForkchoiceStateGen(inconsistentForkchoiceState1, Inconsistency.Head)
inconsistentForkchoiceStateGen(inconsistentForkchoiceState2, Inconsistency.Safe)
inconsistentForkchoiceStateGen(inconsistentForkchoiceState3, Inconsistency.Finalized)

# Verify behavior on a forkchoiceUpdated with invalid payload attributes
template invalidPayloadAttributesGen(procname: untyped, syncingCond: bool) =
  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    # Wait until TTD is reached by this client
    let ok = waitFor t.clMock.waitForTTD()
    testCond ok

    let clMock = t.clMock
    let client = t.rpcClient

    # Produce blocks before starting the test
    var produceBlockRes = clMock.produceBlocks(5, BlockProcessCallbacks())
    testCond produceBlockRes

    # Send a forkchoiceUpdated with invalid PayloadAttributes
    produceBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
      onNewPayloadBroadcast: proc(): bool =
        # Try to apply the new payload with invalid attributes
        var blockHash: common.Hash256
        when syncingCond:
          # Setting a random hash will put the client into `SYNCING`
          doAssert randomBytes(blockHash.data) == 32
        else:
          # Set the block hash to the next payload that was broadcasted
          blockHash = common.Hash256(clMock.latestPayloadBuilt.blockHash)

        let fcu = ForkchoiceStateV1(
          headBlockHash:      Web3BlockHash blockHash.data,
          safeBlockHash:      Web3BlockHash blockHash.data,
          finalizedBlockHash: Web3BlockHash blockHash.data,
        )

        let attr = PayloadAttributesV1()

        # 0) Check headBlock is known and there is no missing data, if not respond with SYNCING
        # 1) Check headBlock is VALID, if not respond with INVALID
        # 2) Apply forkchoiceState
        # 3) Check payloadAttributes, if invalid respond with error: code: Invalid payload attributes
        # 4) Start payload build process and respond with VALID
        when syncingCond:
          # If we are SYNCING, the outcome should be SYNCING regardless of the validity of the payload atttributes
          let r = client.forkchoiceUpdatedV1(fcu, some(attr))
          testFCU(r, syncing)
        else:
          let r = client.forkchoiceUpdatedV1(fcu, some(attr))
          testCond r.isOk:
            error "Unexpected error", msg = r.error

          # Check that the forkchoice was applied, regardless of the error
          testLatestHeader(client, BlockHash blockHash.data)
        return true
    ))

    testCond produceBlockRes

invalidPayloadAttributesGen(invalidPayloadAttributes1, false)
invalidPayloadAttributesGen(invalidPayloadAttributes2, true)

proc preTTDFinalizedBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let
    gHash = Web3BlockHash t.gHeader.blockHash.data
    forkchoiceState = ForkchoiceStateV1(
      headBlockHash:      gHash,
      safeBlockHash:      gHash,
      finalizedBlockHash: gHash,
    )
    client = t.rpcClient
    clMock = t.clMock

  var res = client.forkchoiceUpdatedV1(forkchoiceState)
  testFCU(res, invalid, some(common.Hash256()))

  res = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
  testFCU(res, valid)

# Corrupt the hash of a valid payload, client should reject the payload.
# All possible scenarios:
#    (fcU)
# ┌────────┐        ┌────────────────────────┐
# │  HEAD  │◄───────┤ Bad Hash (!Sync,!Side) │
# └────┬───┘        └────────────────────────┘
#    │
#    │
# ┌────▼───┐        ┌────────────────────────┐
# │ HEAD-1 │◄───────┤ Bad Hash (!Sync, Side) │
# └────┬───┘        └────────────────────────┘
#    │
#
#
#   (fcU)
# ********************  ┌───────────────────────┐
# *  (Unknown) HEAD  *◄─┤ Bad Hash (Sync,!Side) │
# ********************  └───────────────────────┘
#    │
#    │
# ┌────▼───┐            ┌───────────────────────┐
# │ HEAD-1 │◄───────────┤ Bad Hash (Sync, Side) │
# └────┬───┘            └───────────────────────┘
#    │
#

type
  Shadow = ref object
    hash: common.Hash256

template badHashOnNewPayloadGen(procname: untyped, syncingCond: bool, sideChain: bool) =
  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    let ok = waitFor t.clMock.waitForTTD()
    testCond ok

    # Produce blocks before starting the test
    let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
    testCond produce5BlockRes

    let clMock = t.clMock
    let client = t.rpcClient
    let shadow = Shadow()

    var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
      # Run test after the new payload has been obtained
      onGetPayload: proc(): bool =
        # Alter hash on the payload and send it to client, should produce an error
        var alteredPayload = clMock.latestPayloadBuilt
        var invalidPayloadHash = common.Hash256(alteredPayload.blockHash)
        let lastByte = int invalidPayloadHash.data[^1]
        invalidPayloadHash.data[^1] = byte(not lastByte)
        shadow.hash = invalidPayloadHash
        alteredPayload.blockHash = BlockHash invalidPayloadHash.data

        when not syncingCond and sideChain:
          # We alter the payload by setting the parent to a known past block in the
          # canonical chain, which makes this payload a side chain payload, and also an invalid block hash
          # (because we did not update the block hash appropriately)
          alteredPayload.parentHash = Web3BlockHash clMock.latestHeader.parentHash.data
        elif syncingCond:
          # We need to send an fcU to put the client in SYNCING state.
          var randomHeadBlock: common.Hash256
          doAssert randomBytes(randomHeadBlock.data) == 32

          let latestHeaderHash = clMock.latestHeader.blockHash
          let fcU = ForkchoiceStateV1(
            headBlockHash:      Web3BlockHash randomHeadBlock.data,
            safeBlockHash:      Web3BlockHash latestHeaderHash.data,
            finalizedBlockHash: Web3BlockHash latestHeaderHash.data
          )

          let r = client.forkchoiceUpdatedV1(fcU)
          if r.isErr:
            return false
          let z = r.get()
          if z.payloadStatus.status != PayloadExecutionStatus.syncing:
            return false

          when sidechain:
            # Syncing and sidechain, the caonincal head is an unknown payload to us,
            # but this specific bad hash payload is in theory part of a side chain.
            # Therefore the parent we use is the head hash.
            alteredPayload.parentHash = Web3BlockHash latestHeaderHash.data
          else:
            # The invalid bad-hash payload points to the unknown head, but we know it is
            # indeed canonical because the head was set using forkchoiceUpdated.
            alteredPayload.parentHash = Web3BlockHash randomHeadBlock.data

        let res = client.newPayloadV1(alteredPayload)
        # Execution specification::
        # - {status: INVALID_BLOCK_HASH, latestValidHash: null, validationError: null} if the blockHash validation has failed
        if res.isErr:
          return false
        let s = res.get()
        if s.status != PayloadExecutionStatus.invalid_block_hash:
          return false
        s.latestValidHash.isNone
    ))
    testCond produceSingleBlockRes

    # Lastly, attempt to build on top of the invalid payload
    produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
      # Run test after the new payload has been obtained
      onGetPayload: proc(): bool =
        let payload = toExecutableData(clMock.latestPayloadBuilt)
        let alteredPayload = customizePayload(payload, CustomPayload(
          parentHash: some(shadow.hash),
        ))
        let res = client.newPayloadV1(alteredPayload)
        if res.isErr:
          return false
        # Response status can be ACCEPTED (since parent payload could have been thrown out by the client)
        # or INVALID (client still has the payload and can verify that this payload is incorrectly building on top of it),
        # but a VALID response is incorrect.
        let s = res.get()
        s.status != PayloadExecutionStatus.valid
    ))
    testCond produceSingleBlockRes

badHashOnNewPayloadGen(badHashOnNewPayload1, false, false)
badHashOnNewPayloadGen(badHashOnNewPayload2, true, false)
badHashOnNewPayloadGen(badHashOnNewPayload3, false, true)
badHashOnNewPayloadGen(badHashOnNewPayload4, true, true)

proc parentHashOnExecPayload(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Alter hash on the payload and send it to client, should produce an error
      var alteredPayload = clMock.latestPayloadBuilt
      alteredPayload.blockHash = alteredPayload.parentHash
      let res = client.newPayloadV1(alteredPayload)
      if res.isErr:
        return false
      # Execution specification::
      # - {status: INVALID_BLOCK_HASH, latestValidHash: null, validationError: null} if the blockHash validation has failed
      let s = res.get()
      s.status == PayloadExecutionStatus.invalid_block_hash
  ))
  testCond produceSingleBlockRes

# Attempt to re-org to a chain containing an invalid transition payload
proc invalidTransitionPayload(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by main client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  let clMock = t.clMock
  let client = t.rpcClient

  # Produce two blocks before trying to re-org
  t.nonce = 2 # Initial PoW chain already contains 2 transactions
  var pbRes = clMock.produceBlocks(2, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      t.sendTx(1.u256)
  ))

  testCond pbRes

  # Introduce the invalid transition payload
  pbRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # This is being done in the middle of the block building
    # process simply to be able to re-org back.
    onGetPayload: proc(): bool =
      let basePayload = clMock.executedPayloadHistory[clMock.posBlockNumber]
      let alteredPayload = generateInvalidPayload(basePayload, InvalidStateRoot)

      let res = client.newPayloadV1(alteredPayload)
      let cond = {PayloadExecutionStatus.invalid, PayloadExecutionStatus.accepted}
      testNPEither(res, cond, some(common.Hash256()))

      let rr = client.forkchoiceUpdatedV1(
        ForkchoiceStateV1(headBlockHash: alteredPayload.blockHash)
      )
      testFCU(rr, invalid, some(common.Hash256()))

      testLatestHeader(client, clMock.latestExecutedPayload.blockHash)
      return true
  ))

  testCond pbRes

template invalidPayloadTestCaseGen(procName: untyped, payloadField: InvalidPayloadField, emptyTxs: bool = false) =
  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    # Wait until TTD is reached by this client
    let ok = waitFor t.clMock.waitForTTD()
    testCond ok

    let clMock = t.clMock
    let client = t.rpcClient

    template txProc(): bool =
      when not emptyTxs:
        t.sendTx(0.u256)
      else:
        true

    # Produce blocks before starting the test
    var pbRes = clMock.produceBlocks(5, BlockProcessCallbacks(
      # Make sure at least one transaction is included in each block
      onPayloadProducerSelected: proc(): bool =
        txProc()
    ))

    testCond pbRes

    let invalidPayload = Shadow()

    pbRes = clMock.produceSingleBlock(BlockProcessCallbacks(
      # Make sure at least one transaction is included in the payload
      onPayloadProducerSelected: proc(): bool =
        txProc()
      ,
      # Run test after the new payload has been obtained
      onGetPayload: proc(): bool =
        # Alter the payload while maintaining a valid hash and send it to the client, should produce an error

        # We need at least one transaction for most test cases to work
        when not emptyTxs:
          if clMock.latestPayloadBuilt.transactions.len == 0:
            # But if the payload has no transactions, the test is invalid
            error "No transactions in the base payload"
            return false

        let alteredPayload = generateInvalidPayload(clMock.latestPayloadBuilt, payloadField, t.vaultKey)
        invalidPayload.hash = common.Hash256(alteredPayload.blockHash)

        # Depending on the field we modified, we expect a different status
        let rr = client.newPayloadV1(alteredPayload)
        if rr.isErr:
          error "unable to send altered payload", msg=rr.error
          return false
        let s = rr.get()

        when payloadField == InvalidParentHash:
          # Execution specification::
          # {status: ACCEPTED, latestValidHash: null, validationError: null} if the following conditions are met:
          #  - the blockHash of the payload is valid
          #  - the payload doesn't extend the canonical chain
          #  - the payload hasn't been fully validated
          # {status: SYNCING, latestValidHash: null, validationError: null}
          # if the payload extends the canonical chain and requisite data for its validation is missing
          # (the client can assume the payload extends the canonical because the linking payload could be missing)
          if s.status notin {PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted}:
            error "newPayloadV1 status expect syncing or accepted", get=s.status
            return false

          if s.latestValidHash.isSome:
            error "newPayloadV1 latestValidHash not empty"
            return false
        else:
          if s.status != PayloadExecutionStatus.invalid:
            error "newPayloadV1 status expect invalid", get=s.status
            return false

          if s.latestValidHash.isNone:
            return false

          let latestValidHash = s.latestValidHash.get
          if latestValidHash != alteredPayload.parentHash:
            error "latestValidHash is not the same with parentHash",
              expected = alteredPayload.parentHash, get = latestValidHash
            return false

        # Send the forkchoiceUpdated with a reference to the invalid payload.
        let fcState = ForkchoiceStateV1(
          headBlockHash:      alteredPayload.blockHash,
          safeBlockHash:      alteredPayload.blockHash,
          finalizedBlockHash: alteredPayload.blockHash,
        )

        let timestamp = Quantity(alteredPayload.timestamp.int64 + 1)
        let payloadAttr = PayloadAttributesV1(timestamp: timestamp)

        # Execution specification:
        #  {payloadStatus: {status: INVALID, latestValidHash: null, validationError: errorMessage | null}, payloadId: null}
        #  obtained from the Payload validation process if the payload is deemed INVALID
        let rs = client.forkchoiceUpdatedV1(fcState, some(payloadAttr))
        # Execution specification:
        #  {payloadStatus: {status: INVALID, latestValidHash: null, validationError: errorMessage | null}, payloadId: null}
        #  obtained from the Payload validation process if the payload is deemed INVALID
        # Note: SYNCING/ACCEPTED is acceptable here as long as the block produced after this test is produced successfully
        if rs.isErr:
          error "unable to send altered payload", msg=rs.error
          return false

        let z = rs.get()
        if z.payloadStatus.status notin {PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted, PayloadExecutionStatus.invalid}:
          return false

        # Finally, attempt to fetch the invalid payload using the JSON-RPC endpoint
        var header: rpc_types.BlockHeader
        let rp = client.headerByHash(alteredPayload.blockHash.common.Hash256, header)
        rp.isErr
    ))

    testCond pbRes

    # Lastly, attempt to build on top of the invalid payload
    let psb = clMock.produceSingleBlock(BlockProcessCallbacks(
      # Run test after the new payload has been obtained
      onGetPayload: proc(): bool =
        let alteredPayload = customizePayload(clMock.latestPayloadBuilt.toExecutableData, CustomPayload(
          parentHash: some(invalidPayload.hash),
        ))

        info "Sending customized NewPayload: ParentHash",
          fromHash=clMock.latestPayloadBuilt.parentHash, toHash=invalidPayload.hash
        # Response status can be ACCEPTED (since parent payload could have been thrown out by the client)
        # or SYNCING (parent payload is thrown out and also client assumes that the parent is part of canonical chain)
        # or INVALID (client still has the payload and can verify that this payload is incorrectly building on top of it),
        # but a VALID response is incorrect.
        let rr = client.newPayloadV1(alteredPayload)
        if rr.isErr:
          error "unable to send altered payload", msg=rr.error
          return false

        let z = rr.get()
        z.status in {PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted, PayloadExecutionStatus.invalid}
    ))

    testCond psb

invalidPayloadTestCaseGen(invalidPayload1, InvalidParentHash)
invalidPayloadTestCaseGen(invalidPayload2, InvalidStateRoot)
invalidPayloadTestCaseGen(invalidPayload3, InvalidStateRoot, true)
invalidPayloadTestCaseGen(invalidPayload4, InvalidReceiptsRoot)
invalidPayloadTestCaseGen(invalidPayload5, InvalidNumber)
invalidPayloadTestCaseGen(invalidPayload6, InvalidGasLimit)
invalidPayloadTestCaseGen(invalidPayload7, InvalidGasUsed)
invalidPayloadTestCaseGen(invalidPayload8, InvalidTimestamp)
invalidPayloadTestCaseGen(invalidPayload9, InvalidPrevRandao)
invalidPayloadTestCaseGen(invalidPayload10, RemoveTransaction)
invalidPayloadTestCaseGen(invalidPayload11, InvalidTransactionSignature)
invalidPayloadTestCaseGen(invalidPayload12, InvalidTransactionNonce)
invalidPayloadTestCaseGen(invalidPayload13, InvalidTransactionGasPrice)
invalidPayloadTestCaseGen(invalidPayload14, InvalidTransactionGas)
invalidPayloadTestCaseGen(invalidPayload15, InvalidTransactionValue)

# Test to verify Block information available at the Eth RPC after NewPayload
template blockStatusExecPayloadGen(procname: untyped, transitionBlock: bool) =
  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    # Wait until TTD is reached by this client
    let ok = waitFor t.clMock.waitForTTD()
    testCond ok

    # Produce blocks before starting the test, only if we are not testing the transition block
    when not transitionBlock:
      let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
      testCond produce5BlockRes

    let clMock = t.clMock
    let client = t.rpcClient
    let shadow = Shadow()

    var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
      onPayloadProducerSelected: proc(): bool =
        var address: EthAddress
        testCond t.sendTx(address, 1.u256)
        shadow.hash = rlpHash(t.tx)
        return true
      ,
      onNewPayloadBroadcast: proc(): bool =
        testLatestHeader(client, clMock.latestForkchoice.headBlockHash)

        let nRes = client.blockNumber()
        if nRes.isErr:
          error "Unable to get latest block number", msg=nRes.error
          return false

        # Latest block number available via Eth RPC should not have changed at this point
        let latestNumber = nRes.get
        if latestNumber != clMock.latestHeadNumber:
          error "latest block number incorrect after newPayload",
            expected=clMock.latestHeadNumber,
            get=latestNumber
          return false

        # Check that the receipt for the transaction we just sent is still not available
        let rr = client.txReceipt(shadow.hash)
        if rr.isOk:
          error "not expecting receipt"
          return false

        return true
    ))
    testCond produceSingleBlockRes

blockStatusExecPayloadGen(blockStatusExecPayload1, false)
blockStatusExecPayloadGen(blockStatusExecPayload2, true)

type
  MissingAncestorShadow = ref object
    cA: ExecutionPayloadV1
    n: int
    altChainPayloads: seq[ExecutionPayloadV1]

# Attempt to re-org to a chain which at some point contains an unknown payload which is also invalid.
# Then reveal the invalid payload and expect that the client rejects it and rejects forkchoice updated calls to this chain.
# The invalid_index parameter determines how many payloads apart is the common ancestor from the block that invalidates the chain,
# with a value of 1 meaning that the immediate payload after the common ancestor will be invalid.
template invalidMissingAncestorReOrgGen(procName: untyped,
  invalid_index: int, payloadField: InvalidPayloadField, p2psync: bool, emptyTxs: bool) =

  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    # Wait until TTD is reached by this client
    let ok = waitFor t.clMock.waitForTTD()
    testCond ok

    let clMock = t.clMock
    let client = t.rpcClient

    # Produce blocks before starting the test
    testCond clMock.produceBlocks(5, BlockProcessCallbacks())

    let shadow = MissingAncestorShadow(
      # Save the common ancestor
      cA: clMock.latestPayloadBuilt,

      # Amount of blocks to deviate starting from the common ancestor
      n: 10,

      # Slice to save the alternate B chain
      altChainPayloads: @[]
    )

    # Append the common ancestor
    shadow.altChainPayloads.add shadow.cA

    # Produce blocks but at the same time create an alternate chain which contains an invalid payload at some point (INV_P)
    # CommonAncestor◄─▲── P1 ◄─ P2 ◄─ P3 ◄─ ... ◄─ Pn
    #                 │
    #                 └── P1' ◄─ P2' ◄─ ... ◄─ INV_P ◄─ ... ◄─ Pn'
    var pbRes = clMock.produceBlocks(shadow.n, BlockProcessCallbacks(
      onPayloadProducerSelected: proc(): bool =
        # Function to send at least one transaction each block produced.
        # Empty Txs Payload with invalid stateRoot discovered an issue in geth sync, hence this is customizable.
        when not emptyTxs:
          # Send the transaction to the prevRandaoContractAddr
          t.sendTx(1.u256)
        return true
      ,
      onGetPayload: proc(): bool =
        # Insert extraData to ensure we deviate from the main payload, which contains empty extradata
        var alternatePayload = customizePayload(clMock.latestPayloadBuilt, CustomPayload(
          parentHash: some(shadow.altChainPayloads[^1].blockHash.common.Hash256),
          extraData:  some(@[1.byte]),
        ))

        if shadow.altChainPayloads.len == invalid_index:
          alternatePayload = generateInvalidPayload(alternatePayload, payloadField)

        shadow.altChainPayloads.add alternatePayload
        return true
    ))
    testCond pbRes

    pbRes = clMock.produceSingleBlock(BlockProcessCallbacks(
      # Note: We perform the test in the middle of payload creation by the CL Mock, in order to be able to
      # re-org back into this chain and use the new payload without issues.
      onGetPayload: proc(): bool =
        # Now let's send the alternate chain to the client using newPayload/sync
        for i in 1..shadow.n:
          # Send the payload
          var payloadValidStr = "VALID"
          if i == invalid_index:
            payloadValidStr = "INVALID"
          elif i > invalid_index:
            payloadValidStr = "VALID with INVALID ancestor"

          info "Invalid chain payload",
            i = i,
            payloadValidStr = payloadValidStr,
            hash = shadow.altChainPayloads[i].blockHash

          let rr = client.newPayloadV1(shadow.altChainPayloads[i])
          testCond rr.isOk

          let rs = client.forkchoiceUpdatedV1(ForkchoiceStateV1(
            headBlockHash: shadow.altChainPayloads[i].blockHash,
            safeBlockHash: shadow.altChainPayloads[i].blockHash
          ))

          if i == invalid_index:
            # If this is the first payload after the common ancestor, and this is the payload we invalidated,
            # then we have all the information to determine that this payload is invalid.
            testNP(rr, invalid, some(shadow.altChainPayloads[i-1].blockHash.common.Hash256))
          elif i > invalid_index:
            # We have already sent the invalid payload, but the client could've discarded it.
            # In reality the CL will not get to this point because it will have already received the `INVALID`
            # response from the previous payload.
            let cond = {PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing, PayloadExecutionStatus.invalid}
            testNPEither(rr, cond)
          else:
            # This is one of the payloads before the invalid one, therefore is valid.
            let latestValidHash = some(shadow.altChainPayloads[i].blockHash.common.Hash256)
            testNP(rr, valid, latestValidHash)
            testFCU(rs, valid, latestValidHash)


        # Resend the latest correct fcU
        let rx = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
        testCond rx.isOk:
          error "Unexpected error ", msg=rx.error

        # After this point, the CL Mock will send the next payload of the canonical chain
        return true
    ))

    testCond pbRes

invalidMissingAncestorReOrgGen(invalidMissingAncestor1, 1, InvalidStateRoot, false, true)
invalidMissingAncestorReOrgGen(invalidMissingAncestor2, 9, InvalidStateRoot, false, true)
invalidMissingAncestorReOrgGen(invalidMissingAncestor3, 10, InvalidStateRoot, false, true)

template blockStatusHeadBlockGen(procname: untyped, transitionBlock: bool) =
  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    # Wait until TTD is reached by this client
    let ok = waitFor t.clMock.waitForTTD()
    testCond ok

    # Produce blocks before starting the test, only if we are not testing the transition block
    when not transitionBlock:
      let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
      testCond produce5BlockRes

    let clMock = t.clMock
    let client = t.rpcClient
    let shadow = Shadow()

    var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
      onPayloadProducerSelected: proc(): bool =
        var address: EthAddress
        testCond t.sendTx(address, 1.u256)
        shadow.hash = rlpHash(t.tx)
        return true
      ,
      # Run test after a forkchoice with new HeadBlockHash has been broadcasted
      onForkchoiceBroadcast: proc(): bool =
        testLatestHeader(client, clMock.latestForkchoice.headBlockHash)

        let rr = client.txReceipt(shadow.hash)
        if rr.isErr:
          error "unable to get transaction receipt"
          return false

        return true
    ))
    testCond produceSingleBlockRes

blockStatusHeadBlockGen(blockStatusHeadBlock1, false)
blockStatusHeadBlockGen(blockStatusHeadBlock2, true)

proc blockStatusSafeBlock(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let clMock = t.clMock
  let client = t.rpcClient

  # On PoW mode, `safe` tag shall return error.
  var header: common.BlockHeader
  var rr = client.namedHeader("safe", header)
  testCond rr.isErr

  # Wait until this client catches up with latest PoS Block
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # First ForkchoiceUpdated sent was equal to 0x00..00, `safe` should return error now
  rr = client.namedHeader("safe", header)
  testCond rr.isErr

  let pbres = clMock.produceBlocks(3, BlockProcessCallbacks(
    # Run test after a forkchoice with new SafeBlockHash has been broadcasted
    onSafeBlockChange: proc(): bool =
      var header: common.BlockHeader
      let rr = client.namedHeader("safe", header)
      testCond rr.isOk
      let safeBlockHash = common.Hash256(clMock.latestForkchoice.safeBlockHash)
      header.blockHash == safeBlockHash
  ))

  testCond pbres

proc blockStatusFinalizedBlock(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let clMock = t.clMock
  let client = t.rpcClient

  # On PoW mode, `finalized` tag shall return error.
  var header: common.BlockHeader
  var rr = client.namedHeader("finalized", header)
  testCond rr.isErr

  # Wait until this client catches up with latest PoS Block
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # First ForkchoiceUpdated sent was equal to 0x00..00, `finalized` should return error now
  rr = client.namedHeader("finalized", header)
  testCond rr.isErr

  let pbres = clMock.produceBlocks(3, BlockProcessCallbacks(
    # Run test after a forkchoice with new FinalizedBlockHash has been broadcasted
    onFinalizedBlockChange: proc(): bool =
      var header: common.BlockHeader
      let rr = client.namedHeader("finalized", header)
      testCond rr.isOk
      let finalizedBlockHash = common.Hash256(clMock.latestForkchoice.finalizedBlockHash)
      header.blockHash == finalizedBlockHash
  ))

  testCond pbres

proc blockStatusReorg(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onForkchoiceBroadcast: proc(): bool =
      # Verify the client is serving the latest HeadBlock
      var currHeader: common.BlockHeader
      var hRes = client.latestHeader(currHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      var currHash = BlockHash currHeader.blockHash.data
      if currHash != clMock.latestForkchoice.headBlockHash or
         currHash == clMock.latestForkchoice.safeBlockHash or
         currHash == clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match HeadBlock hash", hash=currHash
        return false

      # Reorg back to the previous block (FinalizedBlock)
      let reorgForkchoice = ForkchoiceStateV1(
        headBlockHash:      clMock.latestForkchoice.finalizedBlockHash,
        safeBlockHash:      clMock.latestForkchoice.finalizedBlockHash,
        finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash
      )

      var res = client.forkchoiceUpdatedV1(reorgForkchoice)
      if res.isErr:
        error "Could not send forkchoiceUpdatedV1", msg=res.error
        return false

      var s = res.get()
      if s.payloadStatus.status != PayloadExecutionStatus.valid:
        error "Incorrect status returned after a HeadBlockHash reorg", status=s.payloadStatus.status
        return false

      if s.payloadStatus.latestValidHash.isNone:
        error "Cannot get latestValidHash from payloadStatus"
        return false

      var latestValidHash = s.payloadStatus.latestValidHash.get
      if latestValidHash != reorgForkchoice.headBlockHash:
        error "Incorrect latestValidHash returned after a HeadBlockHash reorg",
          expected=reorgForkchoice.headBlockHash,
          get=latestValidHash
        return false

      # testCond that we reorg to the previous block
      testLatestHeader(client, reorgForkchoice.headBlockHash)

      # Send the HeadBlock again to leave everything back the way it was
      res = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
      if res.isErr:
        error "Could not send forkchoiceUpdatedV1", msg=res.error
        return false

      s = res.get()
      if s.payloadStatus.status != PayloadExecutionStatus.valid:
        error "Incorrect status returned after a HeadBlockHash reorg",
          status=s.payloadStatus.status
        return false

      if s.payloadStatus.latestValidHash.isNone:
        error "Cannot get latestValidHash from payloadStatus"
        return false

      latestValidHash = s.payloadStatus.latestValidHash.get
      if latestValidHash != clMock.latestForkchoice.headBlockHash:
        error "Incorrect latestValidHash returned after a HeadBlockHash reorg",
          expected=clMock.latestForkchoice.headBlockHash,
          get=latestValidHash
        return false
      return true
  ))
  testCond produceSingleBlockRes

proc reExecPayloads(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until this client catches up with latest PoS
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # How many Payloads we are going to re-execute
  var payloadReExecCount = 10

  # Create those blocks
  let produceBlockRes = t.clMock.produceBlocks(payloadReExecCount, BlockProcessCallbacks())
  testCond produceBlockRes

  # Re-execute the payloads
  let client = t.rpcClient
  var hRes = client.blockNumber()
  testCond hRes.isOk:
    error "unable to get blockNumber", msg=hRes.error

  let lastBlock = int(hRes.get)
  info "Started re-executing payloads at block", number=lastBlock

  let
    clMock = t.clMock
    start  = lastBlock - payloadReExecCount + 1

  for i in start..lastBlock:
    if clMock.executedPayloadHistory.hasKey(uint64 i):
      let payload = clMock.executedPayloadHistory[uint64 i]
      let res = client.newPayloadV1(payload)
      testCond res.isOk:
        error "FAIL (%s): Unable to re-execute valid payload", msg=res.error

      let s = res.get()
      testCond s.status == PayloadExecutionStatus.valid:
        error "Unexpected status after re-execute valid payload", status=s.status
    else:
      testCond true:
        error "(test issue) Payload does not exist", index=i

proc multipleNewCanonicalPayloads(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been obtained
    onGetPayload: proc(): bool =
      let payloadCount = 80
      let basePayload = toExecutableData(clMock.latestPayloadBuilt)
      var newPrevRandao: common.Hash256

      # Fabricate and send multiple new payloads by changing the PrevRandao field
      for i in 0..<payloadCount:
        doAssert randomBytes(newPrevRandao.data) == 32
        let newPayload = customizePayload(basePayload, CustomPayload(
          prevRandao: some(newPrevRandao)
        ))

        let res = client.newPayloadV1(newPayload)
        if res.isErr:
          error "Unable to send new valid payload extending canonical chain", msg=res.error
          return false

        let s = res.get()
        if s.status != PayloadExecutionStatus.valid:
          error "Unexpected status after trying to send new valid payload extending canonical chain",
            status=s.status
          return false
      return true
  ))
  # At the end the clMocker continues to try to execute fcU with the original payload, which should not fail
  testCond produceSingleBlockRes

proc outOfOrderPayloads(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # First prepare payloads on a first client, which will also contain multiple transactions

  # We will be also verifying that the transactions are correctly interpreted in the canonical chain,
  # prepare a random account to receive funds.
  const
    amountPerTx  = 1000.u256
    txPerPayload = 20
    payloadCount = 10

  var recipient: EthAddress
  doAssert randomBytes(recipient) == 20

  let clMock = t.clMock
  let client = t.rpcClient
  var produceBlockRes = clMock.produceBlocks(payloadCount, BlockProcessCallbacks(
    # We send the transactions after we got the Payload ID, before the clMocker gets the prepared Payload
    onPayloadProducerSelected: proc(): bool =
      for i in 0..<txPerPayload:
        testCond t.sendTx(recipient, amountPerTx)
      return true
  ))
  testCond produceBlockRes

  let expectedBalance = amountPerTx * u256(payloadCount*txPerPayload)

  # testCond balance on this first client
  let balRes = client.balanceAt(recipient)
  testCond balRes.isOk:
    error "Error while getting balance of funded account"

  let bal = balRes.get()
  testCond expectedBalance == bal

  # TODO: this section need multiple client

# Test that performing a re-org back into a previous block of the canonical chain does not produce errors and the chain
# is still capable of progressing.
proc reorgBack(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  let clMock = t.clMock
  let client = t.rpcClient

  testCond clMock.produceSingleBlock(BlockProcessCallbacks())

  # We are going to reorg back to this previous hash several times
  let previousHash = clMock.latestForkchoice.headBlockHash

  # Produce blocks before starting the test (So we don't try to reorg back to the genesis block)
  let r2 = clMock.produceBlocks(5, BlockProcessCallbacks(
    onForkchoiceBroadcast: proc(): bool =
      # Send a fcU with the HeadBlockHash pointing back to the previous block
      let forkchoiceUpdatedBack = ForkchoiceStateV1(
        headBlockHash:      previousHash,
        safeBlockHash:      previousHash,
        finalizedBlockHash: previousHash,
      )

      # It is only expected that the client does not produce an error and the CL Mocker is able to progress after the re-org
      let r = client.forkchoiceUpdatedV1(forkchoiceUpdatedBack)
      testCond r.isOk:
        error "failed to reorg back", msg = r.error
      return true
  ))
  testCond r2

  # Verify that the client is pointing to the latest payload sent
  testLatestHeader(client, clMock.latestPayloadBuilt.blockHash)

# Test that performs a re-org back to the canonical chain after re-org to syncing/unavailable chain.
type
  SideChainList = ref object
    sidechainPayloads: seq[ExecutionPayloadV1]

proc reorgBackFromSyncing(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce an alternative chain
  let pList = SideChainList()
  let clMock = t.clMock
  let client = t.rpcClient

  let r1 = clMock.produceBlocks(10, BlockProcessCallbacks(
    onGetPayload: proc(): bool =
      # Generate an alternative payload by simply adding extraData to the block
      var altParentHash = clMock.latestPayloadBuilt.parentHash

      if pList.sidechainPayloads.len > 0:
        altParentHash = pList.sidechainPayloads[^1].blockHash

      let executableData = toExecutableData(clMock.latestPayloadBuilt)
      let altPayload = customizePayload(executableData,
        CustomPayload(
          parentHash: some(altParentHash.common.Hash256),
          extraData:  some(@[0x01.byte]),
        ))

      pList.sidechainPayloads.add(altPayload)
      return true
  ))

  testCond r1


  # Produce blocks before starting the test (So we don't try to reorg back to the genesis block)
  let r2= clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetPayload: proc(): bool =
      let r = client.newPayloadV1(pList.sidechainPayloads[^1])
      if r.isErr:
        return false
      let s = r.get()
      if s.status notin {PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted}:
        return false

      # We are going to send one of the alternative payloads and fcU to it
      let len = pList.sidechainPayloads.len
      let forkchoiceUpdatedBack = ForkchoiceStateV1(
        headBlockHash:      pList.sidechainPayloads[len-1].blockHash,
        safeBlockHash:      pList.sidechainPayloads[len-2].blockHash,
        finalizedBlockHash: pList.sidechainPayloads[len-3].blockHash,
      )

      # It is only expected that the client does not produce an error and the CL Mocker is able to progress after the re-org
      let res = client.forkchoiceUpdatedV1(forkchoiceUpdatedBack)
      if res.isErr:
        return false

      let rs = res.get()
      if rs.payloadStatus.status != PayloadExecutionStatus.syncing:
        return false

      rs.payloadStatus.latestValidHash.isNone
      # After this, the clMocker will continue and try to re-org to canonical chain once again
      # clMocker will fail the test if this is not possible, so nothing left to do.
  ))

  testCond r2

type
  TxReorgShadow = ref object
    noTxnPayload: ExecutionPayloadV1
    txHash: common.Hash256

proc transactionReorg(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond t.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Create transactions that modify the state in order to testCond after the reorg.
  const
    txCount      = 5
    contractAddr = hexToByteArray[20]("0000000000000000000000000000000000000317")

  let
    client = t.rpcClient
    clMock = t.clMock
    shadow = TxReorgShadow()

  for i in 0..<txCount:
    # Generate two payloads, one with the transaction and the other one without it
    let pbres = clMock.produceSingleBlock(BlockProcessCallbacks(
      onPayloadProducerSelected: proc(): bool =
        # At this point we have not broadcast the transaction,
        # therefore any payload we get should not contain any transactions
        if not clMock.getNextPayloadID(): return false
        if not clMock.getNextPayload(): return false

        shadow.noTxnPayload = clMock.latestPayloadBuilt
        if shadow.noTxnPayload.transactions.len != 0:
          error "Empty payload contains transactions"
          return false

        # At this point we can broadcast the transaction and it will be included in the next payload
        # Data is the key where a `1` will be stored
        let data = i.u256
        testCond t.sendTx(contractAddr, 0.u256, data.toBytesBE)
        shadow.txHash = rlpHash(t.tx)

        # Get the receipt
        let rr = client.txReceipt(shadow.txHash)
        if rr.isOk:
          error "Receipt obtained before tx included in block"
          return false
        return true
      ,
      onGetPayload: proc(): bool =
        # Check that indeed the payload contains the transaction
        if not txInPayload(clMock.latestPayloadBuilt, shadow.txHash):
          error "Payload built does not contain the transaction"
          return false
        return true
      ,
      onForkchoiceBroadcast: proc(): bool =
        # Transaction is now in the head of the canonical chain, re-org and verify it's removed
        var rr = client.txReceipt(shadow.txHash)
        if rr.isErr:
          error "Unable to obtain transaction receipt"
          return false

        if shadow.noTxnPayload.parentHash != clMock.latestPayloadBuilt.parentHash:
          error "Incorrect parent hash for payloads",
            get = shadow.noTxnPayload.parentHash,
            expect = clMock.latestPayloadBuilt.parentHash
          return false

        if shadow.noTxnPayload.blockHash == clMock.latestPayloadBuilt.blockHash:
          error "Incorrect hash for payloads",
            get = shadow.noTxnPayload.blockHash,
            expect = clMock.latestPayloadBuilt.blockHash
          return false

        let rz = client.newPayloadV1(shadow.noTxnPayload)
        testNP(rz, valid, some(common.Hash256(shadow.noTxnPayload.blockHash)))

        let rx = client.forkchoiceUpdatedV1(ForkchoiceStateV1(
          headBlockHash:      shadow.noTxnPayload.blockHash,
          safeBlockHash:      clMock.latestForkchoice.safeBlockHash,
          finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash
        ))
        testFCU(rx, valid)

        testLatestHeader(client, shadow.noTxnPayload.blockHash)

        let rk = client.txReceipt(shadow.txHash)
        if rk.isOk:
          error "Receipt was obtained when the tx had been re-org'd out"
          return false

        # Re-org back
        let ry = clMock.broadcastForkchoiceUpdated(clMock.latestForkchoice)
        ry.isOk
    ))

    testCond pbres

proc testCondPrevRandaoValue(t: TestEnv, expectedPrevRandao: common.Hash256, blockNumber: uint64): bool =
  let storageKey = blockNumber.u256
  let client = t.rpcClient

  let res = client.storageAt(prevRandaoContractAddr, storageKey)
  if res.isErr:
    error "Unable to get storage", msg=res.error
    return false

  let opcodeValueAtBlock = common.Hash256(data: res.get().toBytesBE)
  if opcodeValueAtBlock != expectedPrevRandao:
    error "Storage does not match prevRandao",
      expected=expectedPrevRandao.data,
      get=opcodeValueAtBlock
    return false
  true

proc sidechainReorg(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond t.clMock.produceBlocks(5, BlockProcessCallbacks())

  let
    client = t.rpcClient
    clMock = t.clMock

  # Produce two payloads, send fcU with first payload, testCond transaction outcome, then reorg, testCond transaction outcome again

  # This single transaction will change its outcome based on the payload
  testCond t.sendTx(0.u256)

  let singleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool =
      # At this point the clMocker has a payload that will result in a specific outcome,
      # we can produce an alternative payload, send it, fcU to it, and verify the changes
      var alternativePrevRandao: common.Hash256
      doAssert randomBytes(alternativePrevRandao.data) == 32

      let timestamp = Quantity toUnix(clMock.latestHeader.timestamp + 1.seconds)
      let payloadAttributes = PayloadAttributesV1(
        timestamp:             timestamp,
        prevRandao:            FixedBytes[32] alternativePrevRandao.data,
        suggestedFeeRecipient: Address clMock.nextFeeRecipient,
      )

      var res = client.forkchoiceUpdatedV1(clMock.latestForkchoice, some(payloadAttributes))
      if res.isErr:
        error "Could not send forkchoiceUpdatedV1", msg=res.error
        return false

      let s = res.get()
      let rr = client.getPayloadV1(s.payloadID.get())
      if rr.isErr:
        error "Could not get alternative payload", msg=rr.error
        return false

      let alternativePayload = rr.get()
      if alternativePayload.transactions.len == 0:
        error "alternative payload does not contain the prevRandao opcode tx"
        return false

      let rx = client.newPayloadV1(alternativePayload)
      if rx.isErr:
        error "Could not send alternative payload", msg=rx.error
        return false

      let alternativePayloadStatus = rx.get()
      if alternativePayloadStatus.status != PayloadExecutionStatus.valid:
        error "Alternative payload response returned Status!=VALID",
          status=alternativePayloadStatus.status
        return false

      # We sent the alternative payload, fcU to it
      let alternativeHeader = toBlockHeader(alternativePayload)
      let rHash = BlockHash alternativeHeader.blockHash.data
      let alternativeFcU = ForkchoiceStateV1(
        headBlockHash:      rHash,
        safeBlockHash:      clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash
      )

      res = client.forkchoiceUpdatedV1(alternativeFcU)
      if res.isErr:
        error "Could not send alternative fcU", msg=res.error
        return false

      let alternativeFcUResp = res.get()
      if alternativeFcUResp.payloadStatus.status != PayloadExecutionStatus.valid:
        error "Alternative fcU response returned Status!=VALID",
          status=alternativeFcUResp.payloadStatus.status
        return false

      # PrevRandao should be the alternative prevRandao we sent
      return testCondPrevRandaoValue(t, alternativePrevRandao, uint64 alternativePayload.blockNumber)
  ))

  testCond singleBlockRes
  # The reorg actually happens after the clMocker continues,
  # verify here that the reorg was successful
  let latestBlockNum = clMock.latestHeadNumber.uint64
  testCond testCondPrevRandaoValue(t, clMock.prevRandaoHistory[latestBlockNum], latestBlockNum)

proc suggestedFeeRecipient(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Amount of transactions to send
  const
    txCount = 20

  # Verify that, in a block with transactions, fees are accrued by the suggestedFeeRecipient
  var feeRecipient: EthAddress
  testCond randomBytes(feeRecipient) == 20

  let
    client = t.rpcClient
    clMock = t.clMock

  # Send multiple transactions
  for i in 0..<txCount:
    # Empty self tx
    discard t.sendTx(vaultAccountAddr, 0.u256)

  # Produce the next block with the fee recipient set
  clMock.nextFeeRecipient = feeRecipient
  testCond clMock.produceSingleBlock(BlockProcessCallbacks())

  # Calculate the fees and testCond that they match the balance of the fee recipient
  var blockIncluded: EthBlock
  var rr = client.latestBlock(blockIncluded)
  testCond rr.isOk:
    error "unable to get latest block", msg=rr.error

  testCond blockIncluded.txs.len == txCount:
    error "not all transactions were included in block",
      expected=txCount,
      get=blockIncluded.txs.len

  testCond blockIncluded.header.coinbase == feeRecipient:
    error "feeRecipient was not set as coinbase",
      expected=feeRecipient,
      get=blockIncluded.header.coinbase

  var feeRecipientFees = 0.u256
  for tx in blockIncluded.txs:
    let effGasTip = tx.effectiveGasTip(blockIncluded.header.fee)
    let tr = client.txReceipt(rlpHash(tx))
    testCond tr.isOk:
      error "unable to obtain receipt", msg=tr.error

    let rec = tr.get()
    let gasUsed = UInt256.fromHex(rec.gasUsed.string)
    feeRecipientFees = feeRecipientFees  + effGasTip.u256 * gasUsed

  var br = client.balanceAt(feeRecipient)
  testCond br.isOk

  var feeRecipientBalance = br.get()
  testCond feeRecipientBalance == feeRecipientFees:
    error "balance does not match fees",
      feeRecipientBalance, feeRecipientFees

  # Produce another block without txns and get the balance again
  clMock.nextFeeRecipient = feeRecipient
  testCond clMock.produceSingleBlock(BlockProcessCallbacks())

  br = client.balanceAt(feeRecipient)
  testCond br.isOk
  feeRecipientBalance = br.get()
  testCond feeRecipientBalance == feeRecipientFees:
    error "balance does not match fees",
      feeRecipientBalance, feeRecipientFees

proc sendTxAsync(t: TestEnv): Future[void] {.async.} =
  let
    clMock = t.clMock
    period = chronos.milliseconds(500)

  while not clMock.ttdReached:
    await sleepAsync(period)
    discard t.sendTx(0.u256)

proc prevRandaoOpcodeTx(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let
    client = t.rpcClient
    clMock = t.clMock
    sendTxFuture = sendTxAsync(t)

  # Wait until TTD is reached by this client
  let ok = waitFor clMock.waitForTTD()
  testCond ok

  # Ideally all blocks up until TTD must have a DIFFICULTY opcode tx in it
  let nr = client.blockNumber()
  testCond nr.isOk:
    error "Unable to get latest block number", msg=nr.error

  let ttdBlockNumber = nr.get()

  # Start
  for i in ttdBlockNumber..ttdBlockNumber:
    # First testCond that the block actually contained the transaction
    var blk: EthBlock
    let res = client.blockByNumber(i, blk)
    testCond res.isOk:
      error "Unable to get block", msg=res.error

    testCond blk.txs.len > 0:
      error "(Test issue) no transactions went in block"

    let storageKey = i.u256
    let rr = client.storageAt(prevRandaoContractAddr, storageKey)
    testCond rr.isOk:
      error "Unable to get storage", msg=rr.error

    let opcodeValueAtBlock = rr.get()
    testCond opcodeValueAtBlock == 2.u256:
      error "Incorrect difficulty value in block",
        expect=2,
        get=opcodeValueAtBlock

  # Send transactions now past TTD, the value of the storage in these blocks must match the prevRandao value
  type
    ShadowTx = ref object
      currentTxIndex: int
      txs: seq[Transaction]

  let shadow = ShadowTx(currentTxIndex: 0)

  let produceBlockRes = clMock.produceBlocks(10, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      testCond t.sendTx(0.u256)
      shadow.txs.add t.tx
      inc shadow.currentTxIndex
      return true
    ,
    onForkchoiceBroadcast: proc(): bool =
      # Check the transaction tracing, which is client specific
      let expectedPrevRandao = clMock.prevRandaoHistory[clMock.latestHeadNumber + 1'u64]
      let res = debugPrevRandaoTransaction(client, shadow.txs[shadow.currentTxIndex-1], expectedPrevRandao)
      if res.isErr:
        error "unable to debug prev randao", msg=res.error
        return false
      return true
  ))

  testCond produceBlockRes

  let rr = client.blockNumber()
  testCond rr.isOk:
    error "Unable to get latest block number"

  let lastBlockNumber = rr.get()
  for i in ttdBlockNumber + 1 ..< lastBlockNumber:
    let expectedPrevRandao = UInt256.fromBytesBE(clMock.prevRandaoHistory[i].data)
    let storageKey = i.u256

    let rz = client.storageAt(prevRandaoContractAddr, storageKey)
    testCond rz.isOk:
      error "Unable to get storage", msg=rz.error

    let storage = rz.get()
    testCond storage == expectedPrevRandao:
      error "Unexpected storage", expected=expectedPrevRandao, get=storage

]#


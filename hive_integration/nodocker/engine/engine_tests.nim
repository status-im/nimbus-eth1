import
  std/tables,
  test_env,
  stew/byteutils,
  chronicles,
  unittest2,
  nimcrypto,
  chronos,
  ./helper,
  ../../../nimbus/transaction,
  ../../../nimbus/rpc/rpc_types,
  ../../../nimbus/merge/mergeutils

type
  TestSpec* = object
    name*: string
    run*: proc(t: TestEnv, testStatusIMPL: var TestStatus)
    ttd*: int64

const
  prevRandaoContractAddr = hexToByteArray[20]("0000000000000000000000000000000000000316")

# Invalid Terminal Block in ForkchoiceUpdated:
# Client must reject ForkchoiceUpdated directives if the referenced HeadBlockHash does not meet the TTD requirement.
proc invalidTerminalBlockForkchoiceUpdated(t: TestEnv, testStatusIMPL: var TestStatus) =
  let
    gHash = Web3BlockHash t.gHeader.blockHash.data
    forkchoiceState = ForkchoiceStateV1(
      headBlockHash:      gHash,
      safeBlockHash:      gHash,
      finalizedBlockHash: gHash,
    )

  let res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceState)

  # Execution specification:
  # {payloadStatus: {status: INVALID_TERMINAL_BLOCK, latestValidHash: null, validationError: errorMessage | null}, payloadId: null}
  # either obtained from the Payload validation process or as a result of validating a PoW block referenced by forkchoiceState.headBlockHash
  check res.isOk

  if res.isErr:
    return

  let s = res.get()
  check s.payloadStatus.status == PayloadExecutionStatus.invalid_terminal_block
  check s.payloadStatus.latestValidHash.isNone
  check s.payloadId.isNone

  # ValidationError is not validated since it can be either null or a string message

# Invalid GetPayload Under PoW: Client must reject GetPayload directives under PoW.
proc invalidGetPayloadUnderPoW(t: TestEnv, testStatusIMPL: var TestStatus) =
  # We start in PoW and try to get an invalid Payload, which should produce an error but nothing should be disrupted.
  let id = PayloadID [1.byte, 2,3,4,5,6,7,8]
  let res = t.rpcClient.getPayloadV1(id)
  check res.isErr

# Invalid Terminal Block in NewPayload:
# Client must reject NewPayload directives if the referenced ParentHash does not meet the TTD requirement.
proc invalidTerminalBlockNewPayload(t: TestEnv, testStatusIMPL: var TestStatus) =
  let gBlock = t.gHeader
  let payload = ExecutableData(
    parentHash:   gBlock.blockHash,
    stateRoot:    gBlock.stateRoot,
    receiptsRoot: BLANK_ROOT_HASH,
    number:       1,
    gasLimit:     gBlock.gasLimit,
    gasUsed:      0,
    timestamp:    gBlock.timestamp + 1.seconds,
    baseFeePerGas:gBlock.baseFee
  )
  let hashedPayload = customizePayload(payload, CustomPayload())
  let res = t.rpcClient.newPayloadV1(hashedPayload)

  # Execution specification:
  # {status: INVALID_TERMINAL_BLOCK, latestValidHash: null, validationError: errorMessage | null}
  # if terminal block conditions are not satisfied
  check res.isOk
  if res.isErr:
    return

  let s = res.get()
  check s.status == PayloadExecutionStatus.invalid_terminal_block
  check s.latestValidHash.isNone

proc unknownHeadBlockHash(t: TestEnv, testStatusIMPL: var TestStatus) =
  let ok = waitFor t.clMock.waitForTTD()
  check ok

  if not ok:
    return

  var randomHash: Hash256
  check nimcrypto.randomBytes(randomHash.data) == 32

  let clMock = t.clMock
  let forkchoiceStateUnknownHeadHash = ForkchoiceStateV1(
    headBlockHash:      BlockHash randomHash.data,
    safeBlockHash:      clMock.latestForkchoice.finalizedBlockHash,
    finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash,
  )

  var res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceStateUnknownHeadHash)
  check res.isOk
  if res.isErr:
    return

  let s = res.get()
  # Execution specification::
  # - {payloadStatus: {status: SYNCING, latestValidHash: null, validationError: null}, payloadId: null}
  #   if forkchoiceState.headBlockHash references an unknown payload or a payload that can't be validated
  #   because requisite data for the validation is missing
  check s.payloadStatus.status == PayloadExecutionStatus.syncing

  # Test again using PayloadAttributes, should also return SYNCING and no PayloadID
  let timestamp = uint64 clMock.latestExecutedPayload.timestamp
  let payloadAttr = PayloadAttributesV1(
    timestamp: Quantity(timestamp + 1)
  )

  res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceStateUnknownHeadHash, some(payloadAttr))
  check res.isOk
  if res.isErr:
    return
  check s.payloadStatus.status == PayloadExecutionStatus.syncing
  check s.payloadId.isNone

proc unknownSafeBlockHash(t: TestEnv, testStatusIMPL: var TestStatus) =
  let ok = waitFor t.clMock.waitForTTD()
  check ok

  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  let produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been broadcast
    onNewPayloadBroadcast: proc(): bool =
      # Generate a random SafeBlock hash
      var randomSafeBlockHash: Hash256
      doAssert nimcrypto.randomBytes(randomSafeBlockHash.data) == 32

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

  check produceSingleBlockRes

proc unknownFinalizedBlockHash(t: TestEnv, testStatusIMPL: var TestStatus) =
  let ok = waitFor t.clMock.waitForTTD()
  check ok

  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  let produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been broadcast
    onNewPayloadBroadcast: proc(): bool =
      # Generate a random SafeBlock hash
      var randomFinalBlockHash: Hash256
      doAssert nimcrypto.randomBytes(randomFinalBlockHash.data) == 32

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

  check produceSingleBlockRes

proc preTTDFinalizedBlockHash(t: TestEnv, testStatusIMPL: var TestStatus) =
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

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
  # TBD: Behavior on this edge-case is undecided, as behavior of the Execution client
  # if not defined on re-orgs to a point before the latest finalized block.

  res = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
  check res.isOk
  if res.isErr:
    return

  let s = res.get()
  check s.payloadStatus.status == PayloadExecutionStatus.valid

proc badHashOnExecPayload(t: TestEnv, testStatusIMPL: var TestStatus) =
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  type
    Shadow = ref object
      hash: Hash256

  let clMock = t.clMock
  let client = t.rpcClient
  let shadow = Shadow()

  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Alter hash on the payload and send it to client, should produce an error
      var alteredPayload = clMock.latestPayloadBuilt
      var invalidPayloadHash = hash256(alteredPayload.blockHash)
      let lastByte = int invalidPayloadHash.data[^1]
      invalidPayloadHash.data[^1] = byte(not lastByte)
      shadow.hash = invalidPayloadHash
      alteredPayload.blockHash = BlockHash invalidPayloadHash.data
      let res = client.newPayloadV1(alteredPayload)
      # Execution specification::
      # - {status: INVALID_BLOCK_HASH, latestValidHash: null, validationError: null} if the blockHash validation has failed
      if res.isErr:
        return false
      let s = res.get()
      s.status == PayloadExecutionStatus.invalid_block_hash
  ))
  check produceSingleBlockRes
  if not produceSingleBlockRes:
    return

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
  check produceSingleBlockRes

proc parentHashOnExecPayload(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

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
  check produceSingleBlockRes

proc invalidPayloadTestCaseGen(payloadField: string): proc (t: TestEnv, testStatusIMPL: var TestStatus) =
  return proc (t: TestEnv, testStatusIMPL: var TestStatus) =
    discard

# Test to verify Block information available at the Eth RPC after NewPayload
proc blockStatusExecPayload(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool =
      # TODO: Ideally, we would need to check that the newPayload returned VALID
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      # Latest block header available via Eth RPC should not have changed at this point
      if lastHash == clMock.latestExecutedPayload.blockHash or
        lastHash != clMock.latestForkchoice.headBlockHash or
        lastHash != clMock.latestForkchoice.safeBlockHash or
        lastHash != clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header incorrect after newPayload", hash=lastHash.toHex
        return false

      let nRes = client.blockNumber()
      if nRes.isErr:
        error "Unable to get latest block number", msg=nRes.error
        return false

      # Latest block number available via Eth RPC should not have changed at this point
      let latestNumber = nRes.get
      if latestNumber != clMock.latestFinalizedNumber:
        error "latest block number incorrect after newPayload",
          expected=clMock.latestFinalizedNumber,
          get=latestNumber
        return false

      return true
  ))
  check produceSingleBlockRes

proc blockStatusHeadBlock(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onHeadBlockForkchoiceBroadcast: proc(): bool =
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      if lastHash != clMock.latestForkchoice.headBlockHash or
         lastHash == clMock.latestForkchoice.safeBlockHash or
         lastHash == clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match HeadBlock hash", hash=lastHash.toHex
        return false
      return true
  ))
  check produceSingleBlockRes

proc blockStatusSafeBlock(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onSafeBlockForkchoiceBroadcast: proc(): bool =
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      if lastHash != clMock.latestForkchoice.headBlockHash or
         lastHash != clMock.latestForkchoice.safeBlockHash or
         lastHash == clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match SafeBlock hash", hash=lastHash.toHex
        return false
      return true
  ))
  check produceSingleBlockRes

proc blockStatusFinalizedBlock(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onFinalizedBlockForkchoiceBroadcast: proc(): bool =
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      if lastHash != clMock.latestForkchoice.headBlockHash or
         lastHash != clMock.latestForkchoice.safeBlockHash or
         lastHash != clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match FinalizedBlock hash", hash=lastHash.toHex
        return false
      return true
  ))
  check produceSingleBlockRes

proc blockStatusReorg(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onHeadBlockForkchoiceBroadcast: proc(): bool =
      # Verify the client is serving the latest HeadBlock
      var currHeader: EthBlockHeader
      var hRes = client.latestHeader(currHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      var currHash = BlockHash currHeader.blockHash.data
      if currHash != clMock.latestForkchoice.headBlockHash or
         currHash == clMock.latestForkchoice.safeBlockHash or
         currHash == clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match HeadBlock hash", hash=currHash.toHex
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
          expected=reorgForkchoice.headBlockHash.toHex,
          get=latestValidHash.toHex
        return false

      # Check that we reorg to the previous block
      hRes = client.latestHeader(currHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      currHash = BlockHash currHeader.blockHash.data
      if currHash != reorgForkchoice.headBlockHash:
        error "`latest` block hash doesn't match reorg hash",
          expected=reorgForkchoice.headBlockHash.toHex,
          get=currHash.toHex
        return false

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
          expected=clMock.latestForkchoice.headBlockHash.toHex,
          get=latestValidHash.toHex
        return false
      return true
  ))
  check produceSingleBlockRes

proc reExecPayloads(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until this client catches up with latest PoS
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # How many Payloads we are going to re-execute
  var payloadReExecCount = 10

  # Create those blocks
  let produceBlockRes = t.clMock.produceBlocks(payloadReExecCount, BlockProcessCallbacks())
  check produceBlockRes
  if not produceBlockRes:
    return

  # Re-execute the payloads
  let client = t.rpcClient
  var hRes = client.blockNumber()
  check hRes.isOk
  if hRes.isErr:
    error "unable to get blockNumber", msg=hRes.error
    return

  let lastBlock = int(hRes.get)
  info "Started re-executing payloads at block", number=lastBlock

  let
    clMock = t.clMock
    start  = lastBlock - payloadReExecCount + 1

  for i in start..lastBlock:
    if clMock.executedPayloadHistory.hasKey(uint64 i):
      let payload = clMock.executedPayloadHistory[uint64 i]
      let res = client.newPayloadV1(payload)
      check res.isOk
      if res.isErr:
        error "FAIL (%s): Unable to re-execute valid payload", msg=res.error
        return

      let s = res.get()
      check s.status == PayloadExecutionStatus.valid
      if s.status != PayloadExecutionStatus.valid:
        error "Unexpected status after re-execute valid payload", status=s.status
        return
    else:
      check false
      error "(test issue) Payload does not exist", index=i
      return

proc multipleNewCanonicalPayloads(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been obtained
    onGetPayload: proc(): bool =
      let payloadCount = 80
      let basePayload = toExecutableData(clMock.latestPayloadBuilt)
      var newPrevRandao: Hash256

      # Fabricate and send multiple new payloads by changing the PrevRandao field
      for i in 0..<payloadCount:
        doAssert nimcrypto.randomBytes(newPrevRandao.data) == 32
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
  # At the end the CLMocker continues to try to execute fcU with the original payload, which should not fail
  check produceSingleBlockRes

proc outOfOrderPayloads(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # First prepare payloads on a first client, which will also contain multiple transactions

  # We will be also verifying that the transactions are correctly interpreted in the canonical chain,
  # prepare a random account to receive funds.
  const
    amountPerTx  = 1000.u256
    txPerPayload = 20
    payloadCount = 10

  var recipient: EthAddress
  doAssert nimcrypto.randomBytes(recipient) == 20

  let clMock = t.clMock
  let client = t.rpcClient
  var produceBlockRes = clMock.produceBlocks(payloadCount, BlockProcessCallbacks(
    # We send the transactions after we got the Payload ID, before the CLMocker gets the prepared Payload
    onPayloadProducerSelected: proc(): bool =
      for i in 0..<txPerPayload:
        let tx = t.makeNextTransaction(recipient, amountPerTx)
        let res = client.sendTransaction(tx)
        if res.isErr:
          error "Unable to send transaction"
          return false
      return true
  ))
  check produceBlockRes

  let expectedBalance = amountPerTx * u256(payloadCount*txPerPayload)

  # Check balance on this first client
  let balRes = client.balanceAt(recipient)
  check balRes.isOk
  if balRes.isErr:
    error "Error while getting balance of funded account"
    return

  let bal = balRes.get()
  check expectedBalance == bal
  if expectedBalance != bal:
    return

  # TODO: this section need multiple client

proc transactionReorg(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  # Create transactions that modify the state in order to check after the reorg.
  const
    txCount      = 5
    contractAddr = hexToByteArray[20]("0000000000000000000000000000000000000317")

  var
    receipts: array[txCount, rpc_types.ReceiptObject]
    txs: array[txCount, Transaction]

  let
    client = t.rpcClient
    clMock = t.clMock

  for i in 0..<txCount:
    # Data is the key where a `1` will be stored
    let data = i.u256
    let tx = t.makeNextTransaction(contractAddr, 0.u256, data.toBytesBE)
    txs[i] = tx

    # Send the transaction
    let res = client.sendTransaction(tx)
    check res.isOk
    if res.isErr:
      error "Unable to send transaction", msg=res.error
      return

    # Produce the block containing the transaction
    var blockRes = clMock.produceSingleBlock(BlockProcessCallbacks())
    check blockRes
    if not blockRes:
      return

    # Get the receipt
    let rr = client.txReceipt(rlpHash(tx))
    check rr.isOk
    if rr.isErr:
      error "Unable to obtain transaction receipt", msg=rr.error
      return

    receipts[i] = rr.get()

  for i in 0..<txCount:
    # The sstore contract stores a `1` to key specified in data
    let storageKey = i.u256

    var rr = client.storageAt(contractAddr, storageKey)
    check rr.isOk
    if rr.isErr:
      error "Could not get storage", msg=rr.error
      return

    let valueWithTxApplied = rr.get()
    check valueWithTxApplied == 1.u256
    if valueWithTxApplied != 1.u256:
      error "Expected storage not set after transaction", valueWithTxApplied
      return

    # Get value at a block before the tx was included
    let number = UInt256.fromHex(receipts[i].blockNumber.string).truncate(uint64)
    var reorgBlock: EthBlockHeader
    let blockRes = client.headerByNumber(number - 1, reorgBlock)
    rr = client.storageAt(contractAddr, storageKey, reorgBlock.blockNumber)
    check rr.isOk
    if rr.isErr:
      error "could not get storage", msg= rr.error
      return

    let valueWithoutTxApplied = rr.get()
    check valueWithoutTxApplied == 0.u256
    if valueWithoutTxApplied != 0.u256:
      error "Storage not unset before transaction!", valueWithoutTxApplied
      return

    # Re-org back to a previous block where the tx is not included using forkchoiceUpdated
    let rHash = Web3BlockHash reorgBlock.blockHash.data
    let reorgForkchoice = ForkchoiceStateV1(
      headBlockHash:      rHash,
      safeBlockHash:      rHash,
      finalizedBlockHash: rHash,
    )

    var res = client.forkchoiceUpdatedV1(reorgForkchoice)
    check res.isOk
    if res.isErr:
      error "Could not send forkchoiceUpdatedV1", msg=res.error
      return

    var s = res.get()
    check s.payloadStatus.status == PayloadExecutionStatus.valid
    if s.payloadStatus.status != PayloadExecutionStatus.valid:
      error "Could not send forkchoiceUpdatedV1", status=s.payloadStatus.status
      return

    # Check storage again using `latest`, should be unset
    rr = client.storageAt( contractAddr, storageKey)
    check rr.isOk
    if rr.isErr:
      error "could not get storage", msg= rr.error
      return

    let valueAfterReOrgBeforeTxApplied = rr.get()
    check valueAfterReOrgBeforeTxApplied == 0.u256
    if valueAfterReOrgBeforeTxApplied != 0.u256:
      error "Storage not unset after re-org", valueAfterReOrgBeforeTxApplied
      return

    # Re-send latest forkchoice to test next transaction
    res = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
    check res.isOk
    if res.isErr:
      error "Could not send forkchoiceUpdatedV1", msg=res.error
      return

    s = res.get()
    check s.payloadStatus.status == PayloadExecutionStatus.valid
    if s.payloadStatus.status != PayloadExecutionStatus.valid:
      error "Could not send forkchoiceUpdatedV1", status=s.payloadStatus.status
      return

proc checkPrevRandaoValue(t: TestEnv, expectedPrevRandao: Hash256, blockNumber: uint64): bool =
  let storageKey = blockNumber.u256
  let client = t.rpcClient

  let res = client.storageAt(prevRandaoContractAddr, storageKey)
  if res.isErr:
    error "Unable to get storage", msg=res.error
    return false

  let opcodeValueAtBlock = Hash256(data: res.get().toBytesBE)
  if opcodeValueAtBlock != expectedPrevRandao:
    error "Storage does not match prevRandao",
      expected=expectedPrevRandao.data.toHex,
      get=opcodeValueAtBlock.data.toHex
    return false
  true

proc sidechainReorg(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  check produce5BlockRes
  if not produce5BlockRes:
    return

  let
    client = t.rpcClient
    clMock = t.clMock

  # Produce two payloads, send fcU with first payload, check transaction outcome, then reorg, check transaction outcome again

  # This single transaction will change its outcome based on the payload
  let tx = t.makeNextTransaction(prevRandaoContractAddr, 0.u256)
  let rr = client.sendTransaction(tx)
  check rr.isOk
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return

  let singleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool =
      # At this point the CLMocker has a payload that will result in a specific outcome,
      # we can produce an alternative payload, send it, fcU to it, and verify the changes
      var alternativePrevRandao: Hash256
      doAssert nimcrypto.randomBytes(alternativePrevRandao.data) == 32

      let timestamp = Quantity toUnix(clMock.latestFinalizedHeader.timestamp + 1.seconds)
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
      return checkPrevRandaoValue(t, alternativePrevRandao, uint64 alternativePayload.blockNumber)
  ))

  check singleBlockRes
  # The reorg actually happens after the CLMocker continues,
  # verify here that the reorg was successful
  let latestBlockNum = cLMock.latestFinalizedNumber.uint64
  check checkPrevRandaoValue(t, clMock.prevRandaoHistory[latestBlockNum], latestBlockNum)

proc suggestedFeeRecipient(t: TestEnv, testStatusIMPL: var TestStatus) =
  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Amount of transactions to send
  const
    txCount = 20

  # Verify that, in a block with transactions, fees are accrued by the suggestedFeeRecipient
  var feeRecipient: EthAddress
  check nimcrypto.randomBytes(feeRecipient) == 20

  let
    client = t.rpcClient
    clMock = t.clMock

  # Send multiple transactions
  for i in 0..<txCount:
    # Empty self tx
    let tx = t.makeNextTransaction(vaultAccountAddr, 0.u256)
    let res = client.sendTransaction(tx)
    check res.isOk
    if res.isErr:
      error "unable to send transaction", msg=res.error
      return

  # Produce the next block with the fee recipient set
  clMock.nextFeeRecipient = feeRecipient
  check clMock.produceSingleBlock(BlockProcessCallbacks())

  # Calculate the fees and check that they match the balance of the fee recipient
  var blockIncluded: EthBlock
  var rr = client.latestBlock(blockIncluded)
  check rr.isOk
  if rr.isErr:
    error "unable to get latest block", msg=rr.error
    return

  check blockIncluded.txs.len == txCount
  if blockIncluded.txs.len != txCount:
    error "not all transactions were included in block",
      expected=txCount,
      get=blockIncluded.txs.len
    return

  check blockIncluded.header.coinbase == feeRecipient
  if blockIncluded.header.coinbase != feeRecipient:
    error "feeRecipient was not set as coinbase",
      expected=feeRecipient.toHex,
      get=blockIncluded.header.coinbase.toHex
    return

  var feeRecipientFees = 0.u256
  for tx in blockIncluded.txs:
    let effGasTip = tx.effectiveGasTip(blockIncluded.header.fee)
    let tr = client.txReceipt(rlpHash(tx))
    check tr.isOk
    if tr.isErr:
      error "unable to obtain receipt", msg=tr.error
      return

    let rec = tr.get()
    let gasUsed = UInt256.fromHex(rec.gasUsed.string)
    feeRecipientFees = feeRecipientFees  + effGasTip.u256 * gasUsed

  var br = client.balanceAt(feeRecipient)
  check br.isOk

  var feeRecipientBalance = br.get()
  check feeRecipientBalance == feeRecipientFees
  if feeRecipientBalance != feeRecipientFees:
    error "balance does not match fees",
      feeRecipientBalance, feeRecipientFees

  # Produce another block without txns and get the balance again
  clMock.nextFeeRecipient = feeRecipient
  check clMock.produceSingleBlock(BlockProcessCallbacks())

  br = client.balanceAt(feeRecipient)
  check br.isOk
  feeRecipientBalance = br.get()
  check feeRecipientBalance == feeRecipientFees
  if feeRecipientBalance != feeRecipientFees:
    error "balance does not match fees",
      feeRecipientBalance, feeRecipientFees

proc prevRandaoOpcodeTx(t: TestEnv, testStatusIMPL: var TestStatus) =
  let
    client = t.rpcClient
    clMock = t.clMock
    tx = t.makeNextTransaction(prevRandaoContractAddr, 0.u256)
    rr = client.sendTransaction(tx)

  check rr.isOk
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return

  # Wait until TTD is reached by this client
  let ok = waitFor clMock.waitForTTD()
  check ok
  if not ok:
    return

  # Ideally all blocks up until TTD must have a DIFFICULTY opcode tx in it
  let nr = client.blockNumber()
  check nr.isOk
  if nr.isErr:
    error "Unable to get latest block number", msg=nr.error
    return

  let ttdBlockNumber = nr.get()

  # Start
  for i in ttdBlockNumber..ttdBlockNumber:
    # First check that the block actually contained the transaction
    var blk: EthBlock
    let res = client.blockByNumber(i, blk)
    check res.isOk
    if res.isErr:
      error "Unable to get block", msg=res.error
      return

    check blk.txs.len > 0
    if blk.txs.len == 0:
      error "(Test issue) no transactions went in block"
      return

    let storageKey = i.u256
    let rr = client.storageAt(prevRandaoContractAddr, storageKey)
    check rr.isOk
    if rr.isErr:
      error "Unable to get storage", msg=rr.error
      return

    let opcodeValueAtBlock = rr.get()
    if opcodeValueAtBlock != 2.u256:
      error "Incorrect difficulty value in block",
        expect=2,
        get=opcodeValueAtBlock
      return

proc postMergeSync(t: TestEnv, testStatusIMPL: var TestStatus) =
  # TODO: need multiple client
  discard

const engineTestList* = [
  TestSpec(
    name: "Invalid Terminal Block in ForkchoiceUpdated",
    run: invalidTerminalBlockForkchoiceUpdated,
    ttd: 1000000
  ),
  TestSpec(
    name: "Invalid GetPayload Under PoW",
    run: invalidGetPayloadUnderPoW,
    ttd: 1000000
  ),
  TestSpec(
    name: "Invalid Terminal Block in NewPayload",
    run:  invalidTerminalBlockNewPayload,
    ttd:  1000000,
  ),
  TestSpec(
    name: "Unknown HeadBlockHash",
    run:  unknownHeadBlockHash,
  ),
  TestSpec(
    name: "Unknown SafeBlockHash",
    run:  unknownSafeBlockHash,
  ),
  TestSpec(
    name: "Unknown FinalizedBlockHash",
    run:  unknownFinalizedBlockHash,
  ),
  TestSpec(
    name: "Pre-TTD ForkchoiceUpdated After PoS Switch",
    run:  preTTDFinalizedBlockHash,
    ttd:  2,
  ),
  TestSpec(
    name: "Bad Hash on NewPayload",
    run:  badHashOnExecPayload,
  ),
  TestSpec(
    name: "ParentHash==BlockHash on NewPayload",
    run:  parentHashOnExecPayload,
  ),
  #[TestSpec(
    name: "Invalid ParentHash NewPayload",
    run:  invalidPayloadTestCaseGen("ParentHash"),
  ),
  TestSpec(
    name: "Invalid StateRoot NewPayload",
    run:  invalidPayloadTestCaseGen("StateRoot"),
  ),
  TestSpec(
    name: "Invalid ReceiptsRoot NewPayload",
    run:  invalidPayloadTestCaseGen("ReceiptsRoot"),
  ),
  TestSpec(
    name: "Invalid Number NewPayload",
    run:  invalidPayloadTestCaseGen("Number"),
  ),
  TestSpec(
    name: "Invalid GasLimit NewPayload",
    run:  invalidPayloadTestCaseGen("GasLimit"),
  ),
  TestSpec(
    name: "Invalid GasUsed NewPayload",
    run:  invalidPayloadTestCaseGen("GasUsed"),
  ),
  TestSpec(
    name: "Invalid Timestamp NewPayload",
    run:  invalidPayloadTestCaseGen("Timestamp"),
  ),
  TestSpec(
    name: "Invalid PrevRandao NewPayload",
    run:  invalidPayloadTestCaseGen("PrevRandao"),
  ),
  TestSpec(
    name: "Invalid Incomplete Transactions NewPayload",
    run:  invalidPayloadTestCaseGen("RemoveTransaction"),
  ),
  TestSpec(
    name: "Invalid Transaction Signature NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Signature"),
  ),
  TestSpec(
    name: "Invalid Transaction Nonce NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Nonce"),
  ),
  TestSpec(
    name: "Invalid Transaction GasPrice NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/GasPrice"),
  ),
  TestSpec(
    name: "Invalid Transaction Gas NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Gas"),
  ),
  TestSpec(
    name: "Invalid Transaction Value NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Value"),
  ),]#

  # Eth RPC Status on ForkchoiceUpdated Events
  TestSpec(
    name: "Latest Block after NewPayload",
    run:  blockStatusExecPayload,
  ),
  TestSpec(
    name: "Latest Block after New HeadBlock",
    run:  blockStatusHeadBlock,
  ),
  TestSpec(
    name: "Latest Block after New SafeBlock",
    run:  blockStatusSafeBlock,
  ),
  TestSpec(
    name: "Latest Block after New FinalizedBlock",
    run:  blockStatusFinalizedBlock,
  ),
  TestSpec(
    name: "Latest Block after Reorg",
    run:  blockStatusReorg,
  ),

  # Payload Tests
  TestSpec(
    name: "Re-Execute Payload",
    run:  reExecPayloads,
  ),
  TestSpec(
    name: "Multiple New Payloads Extending Canonical Chain",
    run:  multipleNewCanonicalPayloads,
  ),
  TestSpec(
    name: "Out of Order Payload Execution",
    run:  outOfOrderPayloads,
  ),

  # Transaction Reorg using Engine API
  TestSpec(
    name: "Transaction Reorg",
    run:  transactionReorg,
  ),
  TestSpec(
    name: "Sidechain Reorg",
    run:  sidechainReorg,
  ),

  # Suggested Fee Recipient in Payload creation
  TestSpec(
    name: "Suggested Fee Recipient Test",
    run:  suggestedFeeRecipient,
  ),

  # TODO: debug and fix
  # PrevRandao opcode tests
 #TestSpec(
 #  name: "PrevRandao Opcode Transactions",
 #  run:  prevRandaoOpcodeTx,
 #  ttd:  10,
 #),

  # Multi-Client Sync tests
  TestSpec(
    name: "Sync Client Post Merge",
    run:  postMergeSync,
    ttd:  10,
  )
]
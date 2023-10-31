import
  std/strutils,
  chronicles,
  ./engine_spec,
  ../helper,
  ../cancun/customizer,
  ../../../../nimbus/common


# Generate test cases for each field of NewPayload, where the payload contains a single invalid field and a valid hash.
type
  InvalidPayloadTestCase* = ref object of EngineSpec
    # invalidField is the field that will be modified to create an invalid payload
    invalidField*: InvalidPayloadBlockField
    # syncing is true if the client is expected to be in syncing mode after receiving the invalid payload
    syncing*: bool
    # emptyTransactions is true if the payload should not contain any transactions
    emptyTransactions*: bool
    # If true, the payload can be detected to be invalid even when syncing,
    # but this check is optional and both `INVALID` and `syncing` are valid responses.
    invalidDetectedOnSync*: bool
    # If true, latest valid hash can be nil for this test.
    nilLatestValidHash*: bool

  InvalidPayloadShadow = ref object
    alteredPayload       : ExecutableData
    invalidDetectedOnSync: bool
    nilLatestValidHash   : bool

method withMainFork(cs: InvalidPayloadTestCase, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InvalidPayloadTestCase): string =
  var name = "Invalid " & $cs.invalidField & " NewPayload"
  if cs.syncing:
    name.add " - syncing"

  if cs.emptyTransactions:
    name.add " - Empty Transactions"

  if cs.txType.get(TxLegacy) == TxEip1559:
    name.add " - "
    name.add $cs.txType.get

  return name

method execute(cs: InvalidPayloadTestCase, env: TestEnv): bool =
  # To allow sending the primary engine client into syncing state,
  # we need a secondary client to guide the payload creation
  let sec = if cs.syncing: env.addEngine()
            else: EngineEnv(nil)

  # Wait until TTD is reached by all clients
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  let txFunc = proc(): bool =
    if not cs.emptyTransactions:
      # Function to send at least one transaction each block produced
      # Send the transaction to the globals.PrevRandaoContractAddr
      let eng = env.clMock.nextBlockProducer
      let ok = env.sendNextTx(
        eng,
        BaseTx(
          recipient:  some(prevRandaoContractAddr),
          amount:     1.u256,
          txType:     cs.txType,
          gasLimit:   75000.GasInt,
        ),
      )
      testCond ok:
        fatal "Error trying to send transaction"
    return true

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks(
    # Make sure at least one transaction is included in each block
    onPayloadProducerSelected: txFunc,
  ))

  if cs.syncing:
    # Disconnect the main engine client from the CL Mocker and produce a block
    env.clMock.removeEngine(env.engine)
    testCond env.clMock.produceSingleBlock(BlockProcessCallbacks(
      onPayloadProducerSelected: txFunc,
    ))

    ## This block is now unknown to the main client, sending an fcU will set it to cs.syncing mode
    let version = env.engine.version(env.clMock.latestPayloadBuilt.timestamp)
    let r = env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice)
    r.expectPayloadStatus(PayloadExecutionStatus.syncing)

  let shadow = InvalidPayloadShadow(
    invalidDetectedOnSync: cs.invalidDetectedOnSync,
    nilLatestValidHash   : cs.nilLatestValidHash,
  )

  var pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    # Make sure at least one transaction is included in the payload
    onPayloadProducerSelected: txFunc,
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Alter the payload while maintaining a valid hash and send it to the client, should produce an error

      # We need at least one transaction for most test cases to work
      if not cs.emptyTransactions and env.clMock.latestPayloadBuilt.transactions.len == 0:
        # But if the payload has no transactions, the test is invalid
        fatal "No transactions in the base payload"
        return false

      let execData = env.clMock.latestExecutableData
      shadow.alteredPayload = env.generateInvalidPayload(execData, cs.invalidField)

      if execData.versionedHashes.isSome and cs.invalidField == RemoveTransaction:
        let vs = execData.versionedHashes.get
        if vs.len > 0:
          # If the payload has versioned hashes, and we removed any transaction, it's highly likely the client will
          # be able to detect the invalid payload even when syncing because of the blob gas used.
          shadow.invalidDetectedOnSync = true
          shadow.nilLatestValidHash = true

      # Depending on the field we modified, we expect a different status
      var version = env.engine.version(shadow.alteredPayload.timestamp)
      let r = env.engine.client.newPayload(version, shadow.alteredPayload)
      if cs.syncing or cs.invalidField == InvalidparentHash:
        # Execution specification::
        # (status: ACCEPTED, latestValidHash: null, validationError: null) if the following conditions are met:
        #  - the blockHash of the payload is valid
        #  - the payload doesn't extend the canonical chain
        #  - the payload hasn't been fully validated
        # (status: syncing, latestValidHash: null, validationError: null)
        # if the payload extends the canonical chain and requisite data for its validation is missing
        # (the client can assume the payload extends the canonical because the linking payload could be missing)
        if shadow.invalidDetectedOnSync:
          # For some fields, the client can detect the invalid payload even when it doesn't have the parent.
          # However this behavior is up to the client, so we can't expect it to happen and syncing is also valid.
          # `VALID` response is still incorrect though.
          r.expectStatusEither([PayloadExecutionStatus.invalid, PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing])
          # TODO: It seems like latestValidHash==nil should always be expected here.
        else:
          r.expectStatusEither([PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing])
          r.expectLatestValidHash()
      else:
        r.expectStatus(PayloadExecutionStatus.invalid)
        if not (shadow.nilLatestValidHash and r.get.latestValidHash.isNone):
          r.expectLatestValidHash(shadow.alteredPayload.parentHash)

      # Send the forkchoiceUpdated with a reference to the invalid payload.
      let fcState = ForkchoiceStateV1(
        headblockHash:      shadow.alteredPayload.blockHash,
        safeblockHash:      shadow.alteredPayload.blockHash,
        finalizedblockHash: shadow.alteredPayload.blockHash,
      )

      var attr = env.clMock.latestPayloadAttributes
      attr.timestamp = w3Qty(shadow.alteredPayload.timestamp, 1)
      attr.prevRandao = w3Hash()
      attr.suggestedFeeRecipient = w3Address()

      # Execution specification:
      #  (payloadStatus: (status: INVALID, latestValidHash: null, validationError: errorMessage | null), payloadId: null)
      #  obtained from the Payload validation process if the payload is deemed INVALID
      version = env.engine.version(shadow.alteredPayload.timestamp)
      let s = env.engine.client.forkchoiceUpdated(version, fcState, some(attr))
      if not cs.syncing:
        # Execution specification:
        #  (payloadStatus: (status: INVALID, latestValidHash: null, validationError: errorMessage | null), payloadId: null)
        #  obtained from the Payload validation process if the payload is deemed INVALID
        # Note: syncing/ACCEPTED is acceptable here as long as the block produced after this test is produced successfully
        s.expectStatusEither([PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted, PayloadExecutionStatus.invalid])
      else:
        # At this moment the response should be syncing
        s.expectPayloadStatus(PayloadExecutionStatus.syncing)

        # When we send the previous payload, the client must now be capable of determining that the invalid payload is actually invalid
        let p = env.engine.client.newPayload(env.clMock.latestExecutedPayload)
        p.expectStatus(PayloadExecutionStatus.valid)
        p.expectLatestValidHash(env.clMock.latestExecutedPayload.blockHash)


        # Another option here could be to send an fcU to the previous payload,
        # but this does not seem like something the CL would do.
        #s = env.engine.client.forkchoiceUpdated(ForkchoiceStateV1(
        #  headblockHash:      previousPayload.blockHash,
        #  safeblockHash:      previousPayload.blockHash,
        #  finalizedblockHash: previousPayload.blockHash,
        #), nil)
        #s.expectPayloadStatus(Valid)


        let q = env.engine.client.newPayload(version, shadow.alteredPayload)
        if cs.invalidField == InvalidparentHash:
          # There is no invalid parentHash, if this value is incorrect,
          # it is assumed that the block is missing and we need to sync.
          # ACCEPTED also valid since the CLs normally use these interchangeably
          q.expectStatusEither([PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted])
          q.expectLatestValidHash()
        elif cs.invalidField == InvalidNumber:
          # A payload with an invalid number can force us to start a sync cycle
          # as we don't know if that block might be a valid future block.
          q.expectStatusEither([PayloadExecutionStatus.invalid, PayloadExecutionStatus.syncing])
          if q.get.status == PayloadExecutionStatus.invalid:
            q.expectLatestValidHash(env.clMock.latestExecutedPayload.blockHash)
          else:
            q.expectLatestValidHash()
        else:
          # Otherwise the response should be INVALID.
          q.expectStatus(PayloadExecutionStatus.invalid)
          if not (shadow.nilLatestValidHash and r.get.latestValidHash.isNone):
            q.expectLatestValidHash(env.clMock.latestExecutedPayload.blockHash)

        # Try sending the fcU again, this time we should get the proper invalid response.
        # At this moment the response should be INVALID
        if cs.invalidField != InvalidparentHash:
          let version = env.engine.version(shadow.alteredPayload.timestamp)
          let s = env.engine.client.forkchoiceUpdated(version, fcState)
          # Note: syncing is acceptable here as long as the block produced after this test is produced successfully
          s.expectStatusEither([PayloadExecutionStatus.syncing, PayloadExecutionStatus.invalid])

      # Finally, attempt to fetch the invalid payload using the JSON-RPC endpoint
      let p = env.engine.client.headerByHash(ethHash shadow.alteredPayload.blockHash)
      p.expectError()
      return true
  ))
  testCond pbRes

  if cs.syncing:
    # Send the valid payload and its corresponding forkchoiceUpdated
    let r = env.engine.client.newPayload(env.clMock.latestExecutedPayload)
    r.expectStatus(PayloadExecutionStatus.valid)
    r.expectLatestValidHash(env.clMock.latestExecutedPayload.blockHash)

    let version = env.engine.version(env.clMock.latestExecutedPayload.timestamp)
    let s = env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice)
    s.expectPayloadStatus(PayloadExecutionStatus.valid)
    s.expectLatestValidHash(env.clMock.latestExecutedPayload.blockHash)

    # Add main client again to the CL Mocker
    env.clMock.addEngine(env.engine)


  # Lastly, attempt to build on top of the invalid payload
  pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      if env.clMock.latestPayloadBuilt.parentHash == shadow.alteredPayload.blockHash:
        # In some instances the payload is indiscernible from the altered one because the
        # difference lies in the new payload parameters, in this case skip this check.
        return true

      let customizer = CustomPayloadData(
        parentHash: some(ethHash shadow.alteredPayload.blockHash),
      )

      let followUpAlteredPayload = customizer.customizePayload(env.clMock.latestExecutableData)
      info "Sending customized Newpayload",
        parentHash=env.clMock.latestPayloadBuilt.parentHash.short,
        hash=shadow.alteredPayload.blockHash.short

      # Response status can be ACCEPTED (since parent payload could have been thrown out by the client)
      # or syncing (parent payload is thrown out and also client assumes that the parent is part of canonical chain)
      # or INVALID (client still has the payload and can verify that this payload is incorrectly building on top of it),
      # but a VALID response is incorrect.
      let version = env.engine.version(followUpAlteredPayload.timestamp)
      let r = env.engine.client.newPayload(version, followUpAlteredPayload)
      r.expectStatusEither([PayloadExecutionStatus.accepted, PayloadExecutionStatus.invalid, PayloadExecutionStatus.syncing])
      if r.get.status in [PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing]:
        r.expectLatestValidHash()
      elif r.get.status == PayloadExecutionStatus.invalid:
        if not (shadow.nilLatestValidHash or r.get.latestValidHash.isNone):
          r.expectLatestValidHash(shadow.alteredPayload.parentHash)

      return true
  ))
  testCond pbRes
  return true

# Build on top of the latest valid payload after an invalid payload had been received:
# P <- INV_P, newPayload(INV_P), fcU(head: P, payloadAttributes: attrs) + getPayload(…)
type
  PayloadBuildAfterInvalidPayloadTest* = ref object of EngineSpec
    invalidField*: InvalidPayloadBlockField

method withMainFork(cs: PayloadBuildAfterInvalidPayloadTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: PayloadBuildAfterInvalidPayloadTest): string =
  "Payload Build after New Invalid payload: Invalid " & $cs.invalidField

method execute(cs: PayloadBuildAfterInvalidPayloadTest, env: TestEnv): bool =
  # Add a second client to build the invalid payload
  let sec = env.addEngine()

  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Produce another block, but at the same time send an invalid payload from the other client
  let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadAttributesGenerated: proc(): bool =
      # We are going to use the client that was not selected
      # by the CLMocker to produce the invalid payload
      var invalidPayloadProducer = env.engine
      if env.clMock.nextBlockProducer == invalidPayloadProducer:
        invalidPayloadProducer = sec

      var inv_p: ExecutableData
      block:
        # Get a payload from the invalid payload producer and invalidate it
        let
          customizer = BasePayloadAttributesCustomizer(
            prevRandao: some(common.Hash256()),
            suggestedFeerecipient: some(ZeroAddr),
          )
          payloadAttributes = customizer.getPayloadAttributes(env.clMock.latestPayloadAttributes)
          version = env.engine.version(env.clMock.latestHeader.timestamp)
          r = invalidPayloadProducer.client.forkchoiceUpdated(version, env.clMock.latestForkchoice, some(payloadAttributes))

        r.expectPayloadStatus(PayloadExecutionStatus.valid)
        # Wait for the payload to be produced by the EL
        let period = chronos.seconds(1)
        waitFor sleepAsync(period)

        let
          versione = env.engine.version(payloadAttributes.timestamp)
          s = invalidPayloadProducer.client.getPayload(r.get.payloadID.get, versione)
        s.expectNoError()

        var src = ExecutableData(basePayload: s.get.executionPayload)
        inv_p = env.generateInvalidPayload(src, InvalidStateRoot)

      # Broadcast the invalid payload
      let
        version = env.engine.version(inv_p.timestamp)
        r = env.engine.client.newPayload(version, inv_p)

      r.expectStatus(PayloadExecutionStatus.invalid)
      r.expectLatestValidHash(env.clMock.latestForkchoice.headblockHash)

      let s = sec.client.newPayload(version, inv_p)
      s.expectStatus(PayloadExecutionStatus.invalid)
      s.expectLatestValidHash(env.clMock.latestForkchoice.headblockHash)

      # Let the block production continue.
      # At this point the selected payload producer will
      # try to continue creating a valid payload.
      return true
  ))
  testCond pbRes
  return true

type
  InvalidTxChainIDTest* = ref object of EngineSpec
  InvalidTxChainIDShadow = ref object
    invalidTx: Transaction

method withMainFork(cs: InvalidTxChainIDTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InvalidTxChainIDTest): string =
  "Build Payload with Invalid ChainID Transaction " & $cs.txType

# Attempt to produce a payload after a transaction with an invalid Chain ID was sent to the client
# using `eth_sendRawTransaction`.
method execute(cs: InvalidTxChainIDTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Send a transaction with an incorrect ChainID.
  # Transaction must be not be included in payload creation.
  var shadow = InvalidTxChainIDShadow()
  let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been broadcast
    onPayloadAttributesGenerated: proc(): bool =
      let txCreator = BaseTx(
        recipient:  some(prevRandaoContractAddr),
        amount:     1.u256,
        txType:     cs.txType,
        gasLimit:   75000,
      )

      let
        sender = env.accounts(0)
        eng = env.clMock.nextBlockProducer
        res = eng.client.nonceAt(sender.address)

      testCond res.isOk:
        fatal "Unable to get address nonce", msg=res.error

      let
        nonce = res.get
        tx = env.makeTx(txCreator, sender, nonce)
        chainId = eng.com.chainId

      let txCustomizerData = CustomTransactionData(
        chainID: some((chainId.uint64 + 1'u64).ChainId)
      )

      shadow.invalidTx = env.customizeTransaction(sender, tx, txCustomizerData)
      testCond env.sendTx(shadow.invalidTx):
        info "Error on sending transaction with incorrect chain ID"

      return true
  ))

  testCond pbRes

  # Verify that the latest payload built does NOT contain the invalid chain Tx
  let txHash = shadow.invalidTx.rlpHash
  if txInPayload(env.clMock.latestPayloadBuilt, txHash):
    fatal "Invalid chain ID tx was included in payload"
    return false

  return true

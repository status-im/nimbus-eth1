import
  std/strutils,
  chronicles,
  ./engine_spec,
  ../cancun/customizer

type
  SidechainReOrgTest* = ref object of EngineSpec

method withMainFork(cs: SidechainReOrgTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: SidechainReOrgTest): string =
  "Sidechain Reorg"

# Reorg to a Sidechain using ForkchoiceUpdated
method execute(cs: SidechainReOrgTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Produce two payloads, send fcU with first payload, check transaction outcome, then reorg, check transaction outcome again

  # This single transaction will change its outcome based on the payload
  tx, err = t.sendNextTx(
    t.TestContext,
    t.Engine,
    BaseTx(
      recipient:  &globals.PrevRandaoContractAddr,
      amount:     big0,
      payload:    nil,
      txType:     cs.txType,
      gasLimit:   75000,
    ),
  )
  if err != nil (
    fatal "Error trying to send transaction: %v", t.TestName, err)
  )
  info "sent tx %v", t.TestName, tx.Hash())

  env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool =
      # At this point the CLMocker has a payload that will result in a specific outcome,
      # we can produce an alternative payload, send it, fcU to it, and verify the changes
      alternativePrevRandao = common.Hash()
      rand.Read(alternativePrevRandao[:])
      timestamp = env.clMock.latestPayloadBuilt.timestamp + 1
      payloadAttributes, err = (BasePayloadAttributesCustomizer(
        Timestamp: &timestamp,
        Random:    &alternativePrevRandao,
      )).getPayloadAttributes(env.clMock.LatestPayloadAttributes)
      if err != nil (
        fatal "Unable to customize payload attributes: %v", t.TestName, err)
      )

      r = env.engine.client.forkchoiceUpdated(
        &env.clMock.latestForkchoice,
        payloadAttributes,
        env.clMock.latestPayloadBuilt.timestamp,
      )
      r.expectNoError()

      await sleepAsync(env.clMock.PayloadProductionClientDelay)

      g = env.engine.client.getPayload(r.Response.PayloadID, payloadAttributes)
      g.expectNoError()
      alternativePayload = g.Payload
      if len(alternativePayload.Transactions) == 0 (
        fatal "alternative payload does not contain the prevRandao opcode tx", t.TestName)
      )

      s = env.engine.client.newPayload(alternativePayload)
      s.expectStatus(PayloadExecutionStatus.valid)
      s.expectLatestValidHash(alternativePayload.blockHash)

      # We sent the alternative payload, fcU to it
      p = env.engine.client.forkchoiceUpdated(api.ForkchoiceStateV1(
        headBlockHash:      alternativePayload.blockHash,
        safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
      ), nil, alternativePayload.timestamp)
      p.expectPayloadStatus(PayloadExecutionStatus.valid)

      # PrevRandao should be the alternative prevRandao we sent
      checkPrevRandaoValue(t, alternativePrevRandao, alternativePayload.blockNumber)
    ),
  ))
  # The reorg actually happens after the CLMocker continues,
  # verify here that the reorg was successful
  latestBlockNum = env.clMock.LatestHeadNumber.Uint64()
  checkPrevRandaoValue(t, env.clMock.PrevRandaoHistory[latestBlockNum], latestBlockNum)

)

# Test performing a re-org that involves removing or modifying a transaction
type
  TransactionReOrgScenario = enum
    TransactionReOrgScenarioReOrgOut            = "Re-Org Out"
    TransactionReOrgScenarioReOrgBackIn         = "Re-Org Back In"
    TransactionReOrgScenarioReOrgDifferentBlock = "Re-Org to Different Block"
    TransactionReOrgScenarioNewPayloadOnRevert  = "New Payload on Revert Back"

type
  TransactionReOrgTest* = ref object of EngineSpec
    TransactionCount int
    Scenario         TransactionReOrgScenario

method withMainFork(cs: TransactionReOrgTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: TransactionReOrgTest): string =
  name = "Transaction Re-Org"
  if s.Scenario != "" (
    name = fmt.Sprintf("%s, %s", name, s.Scenario)
  )
  return name

# Test transaction status after a forkchoiceUpdated re-orgs to an alternative hash where a transaction is not present
method execute(cs: TransactionReOrgTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test (So we don't try to reorg back to the genesis block)
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Create transactions that modify the state in order to check after the reorg.
  var (
    err                error
    txCount            = spec.TransactionCount
    sstoreContractAddr = common.HexToAddress("0000000000000000000000000000000000000317")
  )

  if txCount == 0 (
    # Default is to send 5 transactions
    txCount = 5
  )

  # Send a transaction on each payload of the canonical chain
  sendTransaction = func(i int) (Transaction, error) (
    data = common.LeftPadBytes([]byte(byte(i)), 32)
    t.Logf("transactionReorg, i=%v, data=%v\n", i, data)
    return t.sendNextTx(
      t.TestContext,
      t.Engine,
      BaseTx(
        recipient:  &sstoreContractAddr,
        amount:     big0,
        payload:    data,
        txType:     cs.txType,
        gasLimit:   75000,
        ForkConfig: t.ForkConfig,
      ),
    )

  )

  var (
    altPayload ExecutableData
    nextTx     Transaction
    tx         Transaction
  )

  for i = 0; i < txCount; i++ (

    # Generate two payloads, one with the transaction and the other one without it
    env.clMock.produceSingleBlock(BlockProcessCallbacks(
      OnPayloadAttributesGenerated: proc(): bool =
        # At this point we have not broadcast the transaction.
        if spec.Scenario == TransactionReOrgScenarioReOrgOut (
          # Any payload we get should not contain any
          payloadAttributes = env.clMock.LatestPayloadAttributes
          rand.Read(payloadAttributes.Random[:])
          r = env.engine.client.forkchoiceUpdated(env.clMock.latestForkchoice, payloadAttributes, env.clMock.latestHeader.Time)
          r.expectNoError()
          if r.Response.PayloadID == nil (
            fatal "No payload ID returned by forkchoiceUpdated", t.TestName)
          )
          g = env.engine.client.getPayload(r.Response.PayloadID, payloadAttributes)
          g.expectNoError()
          altPayload = &g.Payload

          if len(altPayload.Transactions) != 0 (
            fatal "Empty payload contains transactions: %v", t.TestName, altPayload)
          )
        )

        if spec.Scenario != TransactionReOrgScenarioReOrgBackIn (
          # At this point we can broadcast the transaction and it will be included in the next payload
          # Data is the key where a `1` will be stored
          tx, err = sendTransaction(i)
          if err != nil (
            fatal "Error trying to send transaction: %v", t.TestName, err)
          )

          # Get the receipt
          ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
          defer cancel()
          receipt, _ = t.Eth.TransactionReceipt(ctx, tx.Hash())
          if receipt != nil (
            fatal "Receipt obtained before tx included in block: %v", t.TestName, receipt)
          )
        )

      ),
      onGetpayload: proc(): bool =
        # Check that indeed the payload contains the transaction
        if tx != nil (
          if !TransactionInPayload(env.clMock.latestPayloadBuilt, tx) (
            fatal "Payload built does not contain the transaction: %v", t.TestName, env.clMock.latestPayloadBuilt)
          )
        )

        if spec.Scenario == TransactionReOrgScenarioReOrgDifferentBlock || spec.Scenario == TransactionReOrgScenarioNewPayloadOnRevert (
          # Create side payload with different hash
          var err error
          customizer = &CustomPayloadData(
            extraData: &([]byte(0x01)),
          )
          altPayload, err = customizer.customizePayload(env.clMock.latestPayloadBuilt)
          if err != nil (
            fatal "Error creating reorg payload %v", err)
          )

          if altPayload.parentHash != env.clMock.latestPayloadBuilt.parentHash (
            fatal "Incorrect parent hash for payloads: %v != %v", t.TestName, altPayload.parentHash, env.clMock.latestPayloadBuilt.parentHash)
          )
          if altPayload.blockHash == env.clMock.latestPayloadBuilt.blockHash (
            fatal "Incorrect hash for payloads: %v == %v", t.TestName, altPayload.blockHash, env.clMock.latestPayloadBuilt.blockHash)
          )
        elif spec.Scenario == TransactionReOrgScenarioReOrgBackIn (
          # At this point we broadcast the transaction and request a new payload from the client that must
          # contain the transaction.
          # Since we are re-orging out and back in on the next block, the verification of this transaction
          # being included happens on the next block
          nextTx, err = sendTransaction(i)
          if err != nil (
            fatal "Error trying to send transaction: %v", t.TestName, err)
          )

          if i == 0 (
            # We actually can only do this once because the transaction carries over and we cannot
            # impede it from being included in the next payload
            forkchoiceUpdated = env.clMock.latestForkchoice
            payloadAttributes = env.clMock.LatestPayloadAttributes
            rand.Read(payloadAttributes.SuggestedFeeRecipient[:])
            f = env.engine.client.forkchoiceUpdated(
              &forkchoiceUpdated,
              &payloadAttributes,
              env.clMock.latestHeader.Time,
            )
            f.expectPayloadStatus(PayloadExecutionStatus.valid)

            # Wait a second for the client to prepare the payload with the included transaction

            await sleepAsync(env.clMock.PayloadProductionClientDelay)

            g = env.engine.client.getPayload(f.Response.PayloadID, env.clMock.LatestPayloadAttributes)
            g.expectNoError()

            if !TransactionInPayload(g.Payload, nextTx) (
              fatal "Payload built does not contain the transaction: %v", t.TestName, g.Payload)
            )

            # Send the new payload and forkchoiceUpdated to it
            n = env.engine.client.newPayload(g.Payload)
            n.expectStatus(PayloadExecutionStatus.valid)

            forkchoiceUpdated.headBlockHash = g.Payload.blockHash

            s = env.engine.client.forkchoiceUpdated(forkchoiceUpdated, nil, g.Payload.timestamp)
            s.expectPayloadStatus(PayloadExecutionStatus.valid)
          )
        )
      ),
      onNewPayloadBroadcast: proc(): bool =
        if tx != nil (
          # Get the receipt
          ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
          defer cancel()
          receipt, _ = t.Eth.TransactionReceipt(ctx, tx.Hash())
          if receipt != nil (
            fatal "Receipt obtained before tx included in block (NewPayload): %v", t.TestName, receipt)
          )
        )
      ),
      onForkchoiceBroadcast: proc(): bool =
        if spec.Scenario != TransactionReOrgScenarioReOrgBackIn (
          # Transaction is now in the head of the canonical chain, re-org and verify it's removed
          # Get the receipt
          txt = env.engine.client.txReceipt(tx.Hash())
          txt.expectBlockHash(env.clMock.latestForkchoice.headBlockHash)

          if altPayload.parentHash != env.clMock.latestPayloadBuilt.parentHash (
            fatal "Incorrect parent hash for payloads: %v != %v", t.TestName, altPayload.parentHash, env.clMock.latestPayloadBuilt.parentHash)
          )
          if altPayload.blockHash == env.clMock.latestPayloadBuilt.blockHash (
            fatal "Incorrect hash for payloads: %v == %v", t.TestName, altPayload.blockHash, env.clMock.latestPayloadBuilt.blockHash)
          )

          if altPayload == nil (
            fatal "No payload to re-org to", t.TestName)
          )
          r = env.engine.client.newPayload(altPayload)
          r.expectStatus(PayloadExecutionStatus.valid)
          r.expectLatestValidHash(altPayload.blockHash)

          s = env.engine.client.forkchoiceUpdated(api.ForkchoiceStateV1(
            headBlockHash:      altPayload.blockHash,
            safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
            finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
          ), nil, altPayload.timestamp)
          s.expectPayloadStatus(PayloadExecutionStatus.valid)

          p = env.engine.client.headerByNumber(Head)
          p.expectHash(altPayload.blockHash)

          txt = env.engine.client.txReceipt(tx.Hash())
          if spec.Scenario == TransactionReOrgScenarioReOrgOut (
            if txt.Receipt != nil (
              receiptJson, _ = json.MarshalIndent(txt.Receipt, "", "  ")
              fatal "Receipt was obtained when the tx had been re-org'd out: %s", t.TestName, receiptJson)
            )
          elif spec.Scenario == TransactionReOrgScenarioReOrgDifferentBlock || spec.Scenario == TransactionReOrgScenarioNewPayloadOnRevert (
            txt.expectBlockHash(altPayload.blockHash)
          )

          # Re-org back
          if spec.Scenario == TransactionReOrgScenarioNewPayloadOnRevert (
            r = env.engine.client.newPayload(env.clMock.latestPayloadBuilt)
            r.expectStatus(PayloadExecutionStatus.valid)
            r.expectLatestValidHash(env.clMock.latestPayloadBuilt.blockHash)
          )
          env.clMock.BroadcastForkchoiceUpdated(env.clMock.latestForkchoice, nil, 1)
        )

        if tx != nil (
          # Now it should be back with main payload
          txt = env.engine.client.txReceipt(tx.Hash())
          txt.expectBlockHash(env.clMock.latestForkchoice.headBlockHash)

          if spec.Scenario != TransactionReOrgScenarioReOrgBackIn (
            tx = nil
          )
        )

        if spec.Scenario == TransactionReOrgScenarioReOrgBackIn && i > 0 (
          # Reasoning: Most of the clients do not re-add blob transactions to the pool
          # after a re-org, so we need to wait until the next tx is sent to actually
          # verify.
          tx = nextTx
        )

      ),
    ))

  )

  if tx != nil (
    # Produce one last block and verify that the block contains the transaction
    env.clMock.produceSingleBlock(BlockProcessCallbacks(
      onForkchoiceBroadcast: proc(): bool =
        if !TransactionInPayload(env.clMock.latestPayloadBuilt, tx) (
          fatal "Payload built does not contain the transaction: %v", t.TestName, env.clMock.latestPayloadBuilt)
        )
        # Get the receipt
        ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
        defer cancel()
        receipt, _ = t.Eth.TransactionReceipt(ctx, tx.Hash())
        if receipt == nil (
          fatal "Receipt not obtained after tx included in block: %v", t.TestName, receipt)
        )
      ),
    ))

  )

)

# Test that performing a re-org back into a previous block of the canonical chain does not produce errors and the chain
# is still capable of progressing.
type
  ReOrgBackToCanonicalTest* = ref object of EngineSpec
    # Depth of the re-org to back in the canonical chain
    ReOrgDepth uint64
    # Number of transactions to send on each payload
    TransactionPerPayload uint64
    # Whether to execute a sidechain payload on the re-org
    ExecuteSidePayloadOnReOrg bool

method withMainFork(cs: ReOrgBackToCanonicalTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ReOrgBackToCanonicalTest): string =
  name = fmt.Sprintf("Re-Org Back into Canonical Chain, Depth=%d", s.ReOrgDepth)

  if s.ExecuteSidePayloadOnReOrg (
    name += ", Execute Side Payload on Re-Org"
  )
  return name

proc getDepth(cs: ReOrgBackToCanonicalTest): int =
  if s.ReOrgDepth == 0 (
    return 3
  )
  return s.ReOrgDepth
)

# Test that performing a re-org back into a previous block of the canonical chain does not produce errors and the chain
# is still capable of progressing.
method execute(cs: ReOrgBackToCanonicalTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Check the CLMock configured safe and finalized
  if env.clMock.slotsToSafe.Cmp(new(big.Int).SetUint64(spec.ReOrgDepth)) <= 0 (
    fatal "[TEST ISSUE] CLMock configured slots to safe less than re-org depth: %v <= %v", t.TestName, env.clMock.slotsToSafe, spec.ReOrgDepth)
  )
  if env.clMock.slotsToFinalized.Cmp(new(big.Int).SetUint64(spec.ReOrgDepth)) <= 0 (
    fatal "[TEST ISSUE] CLMock configured slots to finalized less than re-org depth: %v <= %v", t.TestName, env.clMock.slotsToFinalized, spec.ReOrgDepth)
  )

  # Produce blocks before starting the test (So we don't try to reorg back to the genesis block)
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # We are going to reorg back to a previous hash several times
  previousHash = env.clMock.latestForkchoice.headBlockHash
  previousTimestamp = env.clMock.latestPayloadBuilt.timestamp

  if spec.ExecuteSidePayloadOnReOrg (
    var (
      sidePayload                 ExecutableData
      sidePayloadParentForkchoice api.ForkchoiceStateV1
      sidePayloadParentTimestamp  uint64
    )
    env.clMock.produceSingleBlock(BlockProcessCallbacks(
      OnPayloadAttributesGenerated: proc(): bool =
        payloadAttributes = env.clMock.LatestPayloadAttributes
        rand.Read(payloadAttributes.Random[:])
        r = env.engine.client.forkchoiceUpdated(env.clMock.latestForkchoice, payloadAttributes, env.clMock.latestHeader.Time)
        r.expectNoError()
        if r.Response.PayloadID == nil (
          fatal "No payload ID returned by forkchoiceUpdated", t.TestName)
        )
        g = env.engine.client.getPayload(r.Response.PayloadID, payloadAttributes)
        g.expectNoError()
        sidePayload = &g.Payload
        sidePayloadParentForkchoice = env.clMock.latestForkchoice
        sidePayloadParentTimestamp = env.clMock.latestHeader.Time
      ),
    ))
    # Continue producing blocks until we reach the depth of the re-org
    testCond env.clMock.produceBlocks(int(spec.GetDepth()-1), BlockProcessCallbacks(
      onPayloadProducerSelected: proc(): bool =
        # Send a transaction on each payload of the canonical chain
        var err error
        _, err = t.sendNextTxs(
          t.TestContext,
          t.Engine,
          BaseTx(
            recipient:  &ZeroAddr,
            amount:     big1,
            payload:    nil,
            txType:     cs.txType,
            gasLimit:   75000,
            ForkConfig: t.ForkConfig,
          ),
          spec.TransactionPerPayload,
        )
        if err != nil (
          fatal "Error trying to send transactions: %v", t.TestName, err)
        )
      ),
    ))
    # On the last block, before executing the next payload of the canonical chain,
    # re-org back to the parent of the side payload and execute the side payload first
    env.clMock.produceSingleBlock(BlockProcessCallbacks(
      onGetpayload: proc(): bool =
        # We are about to execute the new payload of the canonical chain, re-org back to
        # the side payload
        f = env.engine.client.forkchoiceUpdated(sidePayloadParentForkchoice, nil, sidePayloadParentTimestamp)
        f.expectPayloadStatus(PayloadExecutionStatus.valid)
        f.expectLatestValidHash(sidePayloadParentForkchoice.headBlockHash)
        # Execute the side payload
        n = env.engine.client.newPayload(sidePayload)
        n.expectStatus(PayloadExecutionStatus.valid)
        n.expectLatestValidHash(sidePayload.blockHash)
        # At this point the next canonical payload will be executed by the CL mock, so we can
        # continue producing blocks
      ),
    ))
  else:
    testCond env.clMock.produceBlocks(int(spec.GetDepth()), BlockProcessCallbacks(
      onForkchoiceBroadcast: proc(): bool =
        # Send a fcU with the headBlockHash pointing back to the previous block
        forkchoiceUpdatedBack = api.ForkchoiceStateV1(
          headBlockHash:      previousHash,
          safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
          finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
        )

        # It is only expected that the client does not produce an error and the CL Mocker is able to progress after the re-org
        r = env.engine.client.forkchoiceUpdated(forkchoiceUpdatedBack, nil, previousTimestamp)
        r.expectNoError()

        # Re-send the ForkchoiceUpdated that the CLMock had sent
        r = env.engine.client.forkchoiceUpdated(env.clMock.latestForkchoice, nil, env.clMock.LatestExecutedPayload.timestamp)
        r.expectNoError()
      ),
    ))
  )

  # Verify that the client is pointing to the latest payload sent
  r = env.engine.client.headerByNumber(Head)
  r.expectHash(env.clMock.latestPayloadBuilt.blockHash)

)

type
  ReOrgBackFromSyncingTest* = ref object of EngineSpec

method withMainFork(cs: ReOrgBackFromSyncingTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ReOrgBackFromSyncingTest): string =
  name = "Re-Org Back to Canonical Chain From Syncing Chain"
  return name
)

# Test that performs a re-org back to the canonical chain after re-org to syncing/unavailable chain.
method execute(cs: ReOrgBackFromSyncingTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce an alternative chain
  sidechainPayloads = make([]ExecutableData, 0)
  testCond env.clMock.produceBlocks(10, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send a transaction on each payload of the canonical chain
      var err error
      _, err = t.sendNextTx(
        t.TestContext,
        t.Engine,
        BaseTx(
          recipient:  &ZeroAddr,
          amount:     big1,
          payload:    nil,
          txType:     cs.txType,
          gasLimit:   75000,
        ),
      )
      if err != nil (
        fatal "Error trying to send transactions: %v", t.TestName, err)
      )
    ),
    onGetpayload: proc(): bool =
      # Check that at least one transaction made it into the payload
      if len(env.clMock.latestPayloadBuilt.Transactions) == 0 (
        fatal "No transactions in payload: %v", t.TestName, env.clMock.latestPayloadBuilt)
      )
      # Generate an alternative payload by simply adding extraData to the block
      altParentHash = env.clMock.latestPayloadBuilt.parentHash
      if len(sidechainPayloads) > 0 (
        altParentHash = sidechainPayloads[len(sidechainPayloads)-1].blockHash
      )
      customizer = &CustomPayloadData(
        parentHash: &altParentHash,
        extraData:  &([]byte(0x01)),
      )
      altPayload, err = customizer.customizePayload(env.clMock.latestPayloadBuilt)
      if err != nil (
        fatal "Unable to customize payload: %v", t.TestName, err)
      )
      sidechainPayloads = append(sidechainPayloads, altPayload)
    ),
  ))

  env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      # Re-org to the unavailable sidechain in the middle of block production
      # to be able to re-org back to the canonical chain
      r = env.engine.client.newPayload(sidechainPayloads[len(sidechainPayloads)-1])
      r.expectStatusEither(PayloadExecutionStatus.syncing, test.Accepted)
      r.expectLatestValidHash(nil)
      # We are going to send one of the alternative payloads and fcU to it
      forkchoiceUpdatedBack = api.ForkchoiceStateV1(
        headBlockHash:      sidechainPayloads[len(sidechainPayloads)-1].blockHash,
        safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
      )

      # It is only expected that the client does not produce an error and the CL Mocker is able to progress after the re-org
      s = env.engine.client.forkchoiceUpdated(forkchoiceUpdatedBack, nil, sidechainPayloads[len(sidechainPayloads)-1].timestamp)
      s.expectLatestValidHash(nil)
      s.expectPayloadStatus(PayloadExecutionStatus.syncing)

      # After this, the CLMocker will continue and try to re-org to canonical chain once again
      # CLMocker will fail the test if this is not possible, so nothing left to do.
    ),
  ))
)

type
  ReOrgPrevValidatedPayloadOnSideChainTest* = ref object of EngineSpec

method withMainFork(cs: ReOrgPrevValidatedPayloadOnSideChainTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ReOrgPrevValidatedPayloadOnSideChainTest): string =
  name = "Re-org to Previously Validated Sidechain Payload"
  return name
)

# Test that performs a re-org to a previously validated payload on a side chain.
method execute(cs: ReOrgPrevValidatedPayloadOnSideChainTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  var (
    sidechainPayloads     = make([]ExecutableData, 0)
    sidechainPayloadCount = 5
  )

  # Produce a canonical chain while at the same time generate a side chain to which we will re-org.
  testCond env.clMock.produceBlocks(sidechainPayloadCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send a transaction on each payload of the canonical chain
      var err error
      _, err = t.sendNextTx(
        t.TestContext,
        t.Engine,
        BaseTx(
          recipient:  &ZeroAddr,
          amount:     big1,
          payload:    nil,
          txType:     cs.txType,
          gasLimit:   75000,
          ForkConfig: t.ForkConfig,
        ),
      )
      if err != nil (
        fatal "Error trying to send transactions: %v", t.TestName, err)
      )
    ),
    onGetpayload: proc(): bool =
      # Check that at least one transaction made it into the payload
      if len(env.clMock.latestPayloadBuilt.Transactions) == 0 (
        fatal "No transactions in payload: %v", t.TestName, env.clMock.latestPayloadBuilt)
      )
      # The side chain will consist simply of the same payloads with extra data appended
      extraData = []byte("side")
      customData = CustomPayloadData(
        extraData: &extraData,
      )
      if len(sidechainPayloads) > 0 (
        customData.parentHash = &sidechainPayloads[len(sidechainPayloads)-1].blockHash
      )
      altPayload, err = customData.customizePayload(env.clMock.latestPayloadBuilt)
      if err != nil (
        fatal "Unable to customize payload: %v", t.TestName, err)
      )
      sidechainPayloads = append(sidechainPayloads, altPayload)

      r = env.engine.client.newPayload(altPayload)
      r.expectStatus(PayloadExecutionStatus.valid)
      r.expectLatestValidHash(altPayload.blockHash)
    ),
  ))

  # Attempt to re-org to one of the sidechain payloads, but not the leaf,
  # and also build a new payload from this sidechain.
  env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      var (
        prevRandao            = common.Hash()
        suggestedFeeRecipient = common.Address(0x12, 0x34)
      )
      rand.Read(prevRandao[:])
      payloadAttributesCustomizer = &BasePayloadAttributesCustomizer(
        Random:                &prevRandao,
        SuggestedFeerecipient: &suggestedFeeRecipient,
      )

      reOrgPayload = sidechainPayloads[len(sidechainPayloads)-2]
      reOrgPayloadAttributes = sidechainPayloads[len(sidechainPayloads)-1].PayloadAttributes

      newPayloadAttributes, err = payloadAttributesCustomizer.getPayloadAttributes(reOrgPayloadAttributes)
      if err != nil (
        fatal "Unable to customize payload attributes: %v", t.TestName, err)
      )

      r = env.engine.client.forkchoiceUpdated(api.ForkchoiceStateV1(
        headBlockHash:      reOrgPayload.blockHash,
        safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
      ), newPayloadAttributes, reOrgPayload.timestamp)
      r.expectPayloadStatus(PayloadExecutionStatus.valid)
      r.expectLatestValidHash(reOrgPayload.blockHash)

      p = env.engine.client.getPayload(r.Response.PayloadID, newPayloadAttributes)
      p.expectPayloadParentHash(reOrgPayload.blockHash)

      s = env.engine.client.newPayload(p.Payload)
      s.expectStatus(PayloadExecutionStatus.valid)
      s.expectLatestValidHash(p.Payload.blockHash)

      # After this, the CLMocker will continue and try to re-org to canonical chain once again
      # CLMocker will fail the test if this is not possible, so nothing left to do.
    ),
  ))
)

type
  SafeReOrgToSideChainTest* = ref object of EngineSpec

method withMainFork(cs: SafeReOrgToSideChainTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: SafeReOrgToSideChainTest): string =
  name = "Safe Re-Org to Side Chain"
  return name
)

# Test that performs a re-org of the safe block to a side chain.
method execute(cs: SafeReOrgToSideChainTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce an alternative chain
  sidechainPayloads = make([]ExecutableData, 0)

  if s.slotsToSafe.Uint64() != 1 (
    fatal "[TEST ISSUE] CLMock configured slots to safe not equal to 1: %v", t.TestName, s.slotsToSafe)
  )
  if s.slotsToFinalized.Uint64() != 2 (
    fatal "[TEST ISSUE] CLMock configured slots to finalized not equal to 2: %v", t.TestName, s.slotsToFinalized)
  )

  # Produce three payloads `P1`, `P2`, `P3`, along with the side chain payloads `P2'`, `P3'`
  # First payload is finalized so no alternative payload
  env.clMock.produceSingleBlock(BlockProcessCallbacks())
  testCond env.clMock.produceBlocks(2, BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      # Generate an alternative payload by simply adding extraData to the block
      altParentHash = env.clMock.latestPayloadBuilt.parentHash
      if len(sidechainPayloads) > 0 (
        altParentHash = sidechainPayloads[len(sidechainPayloads)-1].blockHash
      )
      customizer = &CustomPayloadData(
        parentHash: &altParentHash,
        extraData:  &([]byte(0x01)),
      )
      altPayload, err = customizer.customizePayload(env.clMock.latestPayloadBuilt)
      if err != nil (
        fatal "Unable to customize payload: %v", t.TestName, err)
      )
      sidechainPayloads = append(sidechainPayloads, altPayload)
    ),
  ))

  # Verify current state of labels
  head = env.engine.client.headerByNumber(Head)
  head.expectHash(env.clMock.latestPayloadBuilt.blockHash)

  safe = env.engine.client.headerByNumber(Safe)
  safe.expectHash(env.clMock.executedPayloadHistory[2].blockHash)

  finalized = env.engine.client.headerByNumber(Finalized)
  finalized.expectHash(env.clMock.executedPayloadHistory[1].blockHash)

  # Re-org the safe/head blocks to point to the alternative side chain
  env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      for _, p = range sidechainPayloads (
        r = env.engine.client.newPayload(p)
        r.expectStatusEither(PayloadExecutionStatus.valid, test.Accepted)
      )
      r = env.engine.client.forkchoiceUpdated(api.ForkchoiceStateV1(
        headBlockHash:      sidechainPayloads[1].blockHash,
        safeBlockHash:      sidechainPayloads[0].blockHash,
        finalizedBlockHash: env.clMock.executedPayloadHistory[1].blockHash,
      ), nil, sidechainPayloads[1].timestamp)
      r.expectPayloadStatus(PayloadExecutionStatus.valid)

      head = env.engine.client.headerByNumber(Head)
      head.expectHash(sidechainPayloads[1].blockHash)

      safe = env.engine.client.headerByNumber(Safe)
      safe.expectHash(sidechainPayloads[0].blockHash)

      finalized = env.engine.client.headerByNumber(Finalized)
      finalized.expectHash(env.clMock.executedPayloadHistory[1].blockHash)

    ),
  ))
)

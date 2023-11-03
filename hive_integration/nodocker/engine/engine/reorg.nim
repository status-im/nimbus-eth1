# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  eth/common,
  chronicles,
  ./engine_spec,
  ../cancun/customizer,
  ../helper

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
  let tc = BaseTx(
    recipient:  some(prevRandaoContractAddr),
    txType:     cs.txType,
    gasLimit:   75000,
  )
  let ok2 = env.sendNextTx(env.engine, tc)
  testCond ok2:
    fatal "Error trying to send transaction"

  info "sent tx"

  let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool =
      # At this point the CLMocker has a payload that will result in a specific outcome,
      # we can produce an alternative payload, send it, fcU to it, and verify the changes
      let alternativePrevRandao = common.Hash256.randomBytes()
      let timestamp = w3Qty(env.clMock.latestPayloadBuilt.timestamp, 1)
      let customizer = BasePayloadAttributesCustomizer(
        timestamp:  some(timestamp.uint64),
        prevRandao: some(alternativePrevRandao),
      )

      let attr = customizer.getPayloadAttributes(env.clMock.latestPayloadAttributes)

      var version = env.engine.version(env.clMock.latestPayloadBuilt.timestamp)
      let r = env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice, some(attr))
      r.expectNoError()

      let period = chronos.seconds(env.clMock.payloadProductionClientDelay)
      waitFor sleepAsync(period)

      version = env.engine.version(attr.timestamp)
      let g = env.engine.client.getPayload(r.get.payloadID.get, version)
      g.expectNoError()

      let alternativePayload = g.get.executionPayload
      testCond len(alternativePayload.transactions) > 0:
        fatal "alternative payload does not contain the prevRandao opcode tx"

      let s = env.engine.client.newPayload(alternativePayload)
      s.expectStatus(PayloadExecutionStatus.valid)
      s.expectLatestValidHash(alternativePayload.blockHash)

      # We sent the alternative payload, fcU to it
      let fcu = ForkchoiceStateV1(
        headBlockHash:      alternativePayload.blockHash,
        safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
      )
      version = env.engine.version(alternativePayload.timestamp)
      let p = env.engine.client.forkchoiceUpdated(version, fcu)
      p.expectPayloadStatus(PayloadExecutionStatus.valid)

      # PrevRandao should be the alternative prevRandao we sent
      testCond checkPrevRandaoValue(env.engine.client, alternativePrevRandao, alternativePayload.blockNumber.uint64)
      return true
  ))
  testCond pbRes
  # The reorg actually happens after the CLMocker continues,
  # verify here that the reorg was successful
  let latestBlockNum = env.clMock.latestHeadNumber.uint64
  testCond checkPrevRandaoValue(env.engine.client, env.clMock.prevRandaoHistory[latestBlockNum], latestBlockNum)
  return true

# Test performing a re-org that involves removing or modifying a transaction
type
  TransactionReOrgScenario = enum
    TransactionNoScenario
    TransactionReOrgScenarioReOrgOut            = "Re-Org Out"
    TransactionReOrgScenarioReOrgBackIn         = "Re-Org Back In"
    TransactionReOrgScenarioReOrgDifferentBlock = "Re-Org to Different Block"
    TransactionReOrgScenarioNewPayloadOnRevert  = "New Payload on Revert Back"

type
  TransactionReOrgTest* = ref object of EngineSpec
    transactionCount*: int
    scenario*:         TransactionReOrgScenario

method withMainFork(cs: TransactionReOrgTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: TransactionReOrgTest): string =
  var name = "Transaction Re-Org"
  if cs.scenario != TransactionNoScenario:
    name.add ", " & $cs.scenario
  return name

# Test transaction status after a forkchoiceUpdated re-orgs to an alternative hash where a transaction is not present
method execute(cs: TransactionReOrgTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test (So we don't try to reorg back to the genesis block)
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())
#[
  # Create transactions that modify the state in order to check after the reorg.
  var (
    err                error
    txCount            = cs.transactionCount
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
    shadow.payload ExecutableData
    nextTx     Transaction
    tx         Transaction
  )

  for i = 0; i < txCount; i++ (

    # Generate two payloads, one with the transaction and the other one without it
    env.clMock.produceSingleBlock(BlockProcessCallbacks(
      OnPayloadAttributesGenerated: proc(): bool =
        # At this point we have not broadcast the transaction.
        if cs.scenario == TransactionReOrgScenarioReOrgOut (
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
          shadow.payload = &g.Payload

          if len(shadow.payload.transactions) != 0 (
            fatal "Empty payload contains transactions: %v", t.TestName, shadow.payload)
          )
        )

        if cs.scenario != TransactionReOrgScenarioReOrgBackIn (
          # At this point we can broadcast the transaction and it will be included in the next payload
          # Data is the key where a `1` will be stored
          tx, err = sendTransaction(i)
          testCond ok:
            fatal "Error trying to send transaction: %v", t.TestName, err)
          )

          # Get the receipt
          ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
          defer cancel()
          receipt, _ = t.Eth.TransactionReceipt(ctx, shadow.txHash)
          if receipt != nil (
            fatal "Receipt obtained before tx included in block: %v", t.TestName, receipt)
          )
        )

      ),
      onGetpayload: proc(): bool =
        # Check that indeed the payload contains the transaction
        if shadow.tx.isSome:
          if !TransactionInPayload(env.clMock.latestPayloadBuilt, tx) (
            fatal "Payload built does not contain the transaction: %v", t.TestName, env.clMock.latestPayloadBuilt)
          )
        )

        if cs.scenario == TransactionReOrgScenarioReOrgDifferentBlock || cs.scenario == TransactionReOrgScenarioNewPayloadOnRevert (
          # Create side payload with different hash
          var err error
          customizer = &CustomPayloadData(
            extraData: &([]byte(0x01)),
          )
          shadow.payload, err = customizer.customizePayload(env.clMock.latestPayloadBuilt)
          testCond ok:
            fatal "Error creating reorg payload %v", err)
          )

          if shadow.payload.parentHash != env.clMock.latestPayloadBuilt.parentHash (
            fatal "Incorrect parent hash for payloads: %v != %v", t.TestName, shadow.payload.parentHash, env.clMock.latestPayloadBuilt.parentHash)
          )
          if shadow.payload.blockHash == env.clMock.latestPayloadBuilt.blockHash (
            fatal "Incorrect hash for payloads: %v == %v", t.TestName, shadow.payload.blockHash, env.clMock.latestPayloadBuilt.blockHash)
          )
        elif cs.scenario == TransactionReOrgScenarioReOrgBackIn (
          # At this point we broadcast the transaction and request a new payload from the client that must
          # contain the transaction.
          # Since we are re-orging out and back in on the next block, the verification of this transaction
          # being included happens on the next block
          shadow.nextTx, err = sendTransaction(i)
          testCond ok:
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

            if !TransactionInPayload(g.Payload, shadow.nextTx) (
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
        if shadow.tx.isSome:
          # Get the receipt
          ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
          defer cancel()
          receipt, _ = t.Eth.TransactionReceipt(ctx, shadow.txHash)
          if receipt != nil (
            fatal "Receipt obtained before tx included in block (NewPayload): %v", t.TestName, receipt)
          )
        )
      ),
      onForkchoiceBroadcast: proc(): bool =
        if cs.scenario != TransactionReOrgScenarioReOrgBackIn (
          # Transaction is now in the head of the canonical chain, re-org and verify it's removed
          # Get the receipt
          txt = env.engine.client.txReceipt(shadow.txHash)
          txt.expectBlockHash(env.clMock.latestForkchoice.headBlockHash)

          if shadow.payload.parentHash != env.clMock.latestPayloadBuilt.parentHash (
            fatal "Incorrect parent hash for payloads: %v != %v", t.TestName, shadow.payload.parentHash, env.clMock.latestPayloadBuilt.parentHash)
          )
          if shadow.payload.blockHash == env.clMock.latestPayloadBuilt.blockHash (
            fatal "Incorrect hash for payloads: %v == %v", t.TestName, shadow.payload.blockHash, env.clMock.latestPayloadBuilt.blockHash)
          )

          if shadow.payload == nil (
            fatal "No payload to re-org to", t.TestName)
          )
          r = env.engine.client.newPayload(shadow.payload)
          r.expectStatus(PayloadExecutionStatus.valid)
          r.expectLatestValidHash(shadow.payload.blockHash)

          s = env.engine.client.forkchoiceUpdated(api.ForkchoiceStateV1(
            headBlockHash:      shadow.payload.blockHash,
            safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
            finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
          ), nil, shadow.payload.timestamp)
          s.expectPayloadStatus(PayloadExecutionStatus.valid)

          p = env.engine.client.headerByNumber(Head)
          p.expectHash(shadow.payload.blockHash)

          txt = env.engine.client.txReceipt(shadow.txHash)
          if cs.scenario == TransactionReOrgScenarioReOrgOut (
            if txt.Receipt != nil (
              receiptJson, _ = json.MarshalIndent(txt.Receipt, "", "  ")
              fatal "Receipt was obtained when the tx had been re-org'd out: %s", t.TestName, receiptJson)
            )
          elif cs.scenario == TransactionReOrgScenarioReOrgDifferentBlock || cs.scenario == TransactionReOrgScenarioNewPayloadOnRevert (
            txt.expectBlockHash(shadow.payload.blockHash)
          )

          # Re-org back
          if cs.scenario == TransactionReOrgScenarioNewPayloadOnRevert (
            r = env.engine.client.newPayload(env.clMock.latestPayloadBuilt)
            r.expectStatus(PayloadExecutionStatus.valid)
            r.expectLatestValidHash(env.clMock.latestPayloadBuilt.blockHash)
          )
          env.clMock.BroadcastForkchoiceUpdated(env.clMock.latestForkchoice, nil, 1)
        )

        if shadow.tx.isSome:
          # Now it should be back with main payload
          txt = env.engine.client.txReceipt(shadow.txHash)
          txt.expectBlockHash(env.clMock.latestForkchoice.headBlockHash)

          if cs.scenario != TransactionReOrgScenarioReOrgBackIn (
            tx = nil
          )
        )

        if cs.scenario == TransactionReOrgScenarioReOrgBackIn && i > 0 (
          # Reasoning: Most of the clients do not re-add blob transactions to the pool
          # after a re-org, so we need to wait until the next tx is sent to actually
          # verify.
          tx = shadow.nextTx
        )

      ),
    ))

  )

  if shadow.tx.isSome:
    # Produce one last block and verify that the block contains the transaction
    env.clMock.produceSingleBlock(BlockProcessCallbacks(
      onForkchoiceBroadcast: proc(): bool =
        if !TransactionInPayload(env.clMock.latestPayloadBuilt, tx) (
          fatal "Payload built does not contain the transaction: %v", t.TestName, env.clMock.latestPayloadBuilt)
        )
        # Get the receipt
        ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
        defer cancel()
        receipt, _ = t.Eth.TransactionReceipt(ctx, shadow.txHash)
        if receipt == nil (
          fatal "Receipt not obtained after tx included in block: %v", t.TestName, receipt)
        )
      ),
    ))

  )

)
]#

# Test that performing a re-org back into a previous block of the canonical chain does not produce errors and the chain
# is still capable of progressing.
type
  ReOrgBackToCanonicalTest* = ref object of EngineSpec
    # Depth of the re-org to back in the canonical chain
    reOrgDepth*: int
    # Number of transactions to send on each payload
    transactionPerPayload*: int
    # Whether to execute a sidechain payload on the re-org
    executeSidePayloadOnReOrg*: bool

method withMainFork(cs: ReOrgBackToCanonicalTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ReOrgBackToCanonicalTest): string =
  var name = "Re-Org Back into Canonical Chain, Depth=" & $cs.reOrgDepth

  if cs.executeSidePayloadOnReOrg:
    name.add ", Execute Side Payload on Re-Org"
  return name

proc getDepth(cs: ReOrgBackToCanonicalTest): int =
  if cs.reOrgDepth == 0:
    return 3
  return cs.reOrgDepth

# Test that performing a re-org back into a previous block of the canonical chain does not produce errors and the chain
# is still capable of progressing.
method execute(cs: ReOrgBackToCanonicalTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Check the CLMock configured safe and finalized
  testCond env.clMock.slotsToSafe > cs.reOrgDepth:
    fatal "[TEST ISSUE] CLMock configured slots to safe less than re-org depth"

  testCond env.clMock.slotsToFinalized > cs.reOrgDepth:
    fatal "[TEST ISSUE] CLMock configured slots to finalized less than re-org depth"

  # Produce blocks before starting the test (So we don't try to reorg back to the genesis block)
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

#[
  # We are going to reorg back to a previous hash several times
  previousHash = env.clMock.latestForkchoice.headBlockHash
  previousTimestamp = env.clMock.latestPayloadBuilt.timestamp

  if cs.executeSidePayloadOnReOrg (
    var (
      shadow.payload                 ExecutableData
      shadow.parentForkchoice api.ForkchoiceStateV1
      shadow.parentTimestamp  uint64
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
        shadow.payload = &g.Payload
        shadow.parentForkchoice = env.clMock.latestForkchoice
        shadow.parentTimestamp = env.clMock.latestHeader.Time
      ),
    ))
    # Continue producing blocks until we reach the depth of the re-org
    testCond env.clMock.produceBlocks(int(cs.GetDepth()-1), BlockProcessCallbacks(
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
          cs.transactionPerPayload,
        )
        testCond ok:
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
        f = env.engine.client.forkchoiceUpdated(shadow.parentForkchoice, nil, shadow.parentTimestamp)
        f.expectPayloadStatus(PayloadExecutionStatus.valid)
        f.expectLatestValidHash(shadow.parentForkchoice.headBlockHash)
        # Execute the side payload
        n = env.engine.client.newPayload(shadow.payload)
        n.expectStatus(PayloadExecutionStatus.valid)
        n.expectLatestValidHash(shadow.payload.blockHash)
        # At this point the next canonical payload will be executed by the CL mock, so we can
        # continue producing blocks
      ),
    ))
  else:
    testCond env.clMock.produceBlocks(int(cs.GetDepth()), BlockProcessCallbacks(
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
]#

type
  ReOrgBackFromSyncingTest* = ref object of EngineSpec

  Shadow = ref object
    payloads: seq[ExecutableData]

method withMainFork(cs: ReOrgBackFromSyncingTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ReOrgBackFromSyncingTest): string =
  "Re-Org Back to Canonical Chain From Syncing Chain"

# Test that performs a re-org back to the canonical chain after re-org to syncing/unavailable chain.
method execute(cs: ReOrgBackFromSyncingTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce an alternative chain
  var shadow = Shadow()
  var pbRes = env.clMock.produceBlocks(10, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send a transaction on each payload of the canonical chain
      let tc = BaseTx(
        recipient:  some(ZeroAddr),
        amount:     1.u256,
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let ok = env.sendNextTx(env.engine, tc)
      testCond ok:
        fatal "Error trying to send transactions"
      return true
    ,
    onGetpayload: proc(): bool =
      # Check that at least one transaction made it into the payload
      testCond len(env.clMock.latestPayloadBuilt.transactions) > 0:
        fatal "No transactions in payload"

      # Generate an alternative payload by simply adding extraData to the block
      var altParentHash = env.clMock.latestPayloadBuilt.parentHash
      if len(shadow.payloads) > 0:
        altParentHash = shadow.payloads[^1].blockHash

      let customizer = CustomPayloadData(
        parentHash: some(ethHash altParentHash),
        extraData:  some(@[0x01.byte]),
      )

      let payload = customizer.customizePayload(env.clMock.latestExecutableData)
      shadow.payloads.add payload
      return true
  ))

  testCond pbRes

  pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      # Re-org to the unavailable sidechain in the middle of block production
      # to be able to re-org back to the canonical chain
      var version = env.engine.version(shadow.payloads[^1].timestamp)
      let r = env.engine.client.newPayload(version, shadow.payloads[^1])
      r.expectStatusEither([PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted])
      r.expectLatestValidHash()

      # We are going to send one of the alternative payloads and fcU to it
      let fcu = ForkchoiceStateV1(
        headBlockHash:      shadow.payloads[^1].blockHash,
        safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
      )

      # It is only expected that the client does not produce an error and the CL Mocker is able to progress after the re-org
      version = env.engine.version(shadow.payloads[^1].timestamp)
      let s = env.engine.client.forkchoiceUpdated(version, fcu)
      s.expectLatestValidHash()
      s.expectPayloadStatus(PayloadExecutionStatus.syncing)

      # After this, the CLMocker will continue and try to re-org to canonical chain once again
      # CLMocker will fail the test if this is not possible, so nothing left to do.
      return true
  ))
  testCond pbRes
  return true

type
  ReOrgPrevValidatedPayloadOnSideChainTest* = ref object of EngineSpec

method withMainFork(cs: ReOrgPrevValidatedPayloadOnSideChainTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ReOrgPrevValidatedPayloadOnSideChainTest): string =
  "Re-org to Previously Validated Sidechain Payload"

func toSeq(x: string): seq[byte] =
  for z in x:
    result.add z.byte

func ethAddress(a, b: int): EthAddress =
  result[0] = a.byte
  result[1] = b.byte

# Test that performs a re-org to a previously validated payload on a side chain.
method execute(cs: ReOrgPrevValidatedPayloadOnSideChainTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  var shadow = Shadow()

  # Produce a canonical chain while at the same time generate a side chain to which we will re-org.
  var pbRes = env.clMock.produceBlocks(5, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send a transaction on each payload of the canonical chain
      let tc = BaseTx(
        recipient:  some(ZeroAddr),
        amount:     1.u256,
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let ok = env.sendNextTx(env.engine, tc)
      testCond ok:
        fatal "Error trying to send transactions"
      return true
    ,
    onGetpayload: proc(): bool =
      # Check that at least one transaction made it into the payload
      testCond len(env.clMock.latestPayloadBuilt.transactions) > 0:
        fatal "No transactions in payload"

      # The side chain will consist simply of the same payloads with extra data appended
      var customData = CustomPayloadData(
        extraData: some(toSeq("side")),
      )

      if len(shadow.payloads) > 0:
        customData.parentHash = some(ethHash shadow.payloads[^1].blockHash)

      let payload = customData.customizePayload(env.clMock.latestExecutableData)
      shadow.payloads.add  payload

      let version = env.engine.version(payload.timestamp)
      let r = env.engine.client.newPayload(version, payload)
      r.expectStatus(PayloadExecutionStatus.valid)
      r.expectLatestValidHash(payload.blockHash)
      return true
  ))

  testCond pbRes

  # Attempt to re-org to one of the sidechain payloads, but not the leaf,
  # and also build a new payload from this sidechain.
  pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      var
        prevRandao            = common.Hash256.randomBytes()
        suggestedFeeRecipient = ethAddress(0x12, 0x34)

      let payloadAttributesCustomizer = BasePayloadAttributesCustomizer(
        prevRandao:            some(prevRandao),
        suggestedFeerecipient: some(suggestedFeeRecipient),
      )

      let reOrgPayload = shadow.payloads[^2]
      let reOrgPayloadAttributes = shadow.payloads[^1].attr
      let newPayloadAttributes = payloadAttributesCustomizer.getPayloadAttributes(reOrgPayloadAttributes)
      let fcu = ForkchoiceStateV1(
        headBlockHash:      reOrgPayload.blockHash,
        safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
      )

      var version = env.engine.version(reOrgPayload.timestamp)
      let r = env.engine.client.forkchoiceUpdated(version, fcu, some(newPayloadAttributes))
      r.expectPayloadStatus(PayloadExecutionStatus.valid)
      r.expectLatestValidHash(reOrgPayload.blockHash)

      version = env.engine.version(newPayloadAttributes.timestamp)
      let p = env.engine.client.getPayload(r.get.payloadID.get, version)
      p.expectPayloadParentHash(reOrgPayload.blockHash)

      let payload = p.get.executionPayload
      let s = env.engine.client.newPayload(payload)
      s.expectStatus(PayloadExecutionStatus.valid)
      s.expectLatestValidHash(payload.blockHash)

      # After this, the CLMocker will continue and try to re-org to canonical chain once again
      # CLMocker will fail the test if this is not possible, so nothing left to do.
      return true
  ))
  testCond pbRes
  return true

type
  SafeReOrgToSideChainTest* = ref object of EngineSpec

method withMainFork(cs: SafeReOrgToSideChainTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: SafeReOrgToSideChainTest): string =
  "Safe Re-Org to Side Chain"

# Test that performs a re-org of the safe block to a side chain.
method execute(cs: SafeReOrgToSideChainTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce an alternative chain
  var shadow = Shadow()

  testCond cs.slotsToSafe == 1:
    fatal "[TEST ISSUE] CLMock configured slots to safe not equal to 1"

  testCond cs.slotsToFinalized == 2:
    fatal "[TEST ISSUE] CLMock configured slots to finalized not equal to 2"

  # Produce three payloads `P1`, `P2`, `P3`, along with the side chain payloads `P2'`, `P3'`
  # First payload is finalized so no alternative payload
  testCond env.clMock.produceSingleBlock(BlockProcessCallbacks())

  testCond env.clMock.produceBlocks(2, BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      # Generate an alternative payload by simply adding extraData to the block
      var altParentHash = env.clMock.latestPayloadBuilt.parentHash
      if len(shadow.payloads) > 0:
        altParentHash = shadow.payloads[^1].blockHash

      let customizer = CustomPayloadData(
        parentHash: some(ethHash altParentHash),
        extraData:  some(@[0x01.byte]),
      )

      let payload = customizer.customizePayload(env.clMock.latestExecutableData)
      shadow.payloads.add payload
      return true
  ))

  # Verify current state of labels
  let head = env.engine.client.namedHeader(Head)
  head.expectHash(ethHash env.clMock.latestPayloadBuilt.blockHash)

  let safe = env.engine.client.namedHeader(Safe)
  safe.expectHash(ethHash env.clMock.executedPayloadHistory[2].blockHash)

  let finalized = env.engine.client.namedHeader(Finalized)
  finalized.expectHash(ethHash env.clMock.executedPayloadHistory[1].blockHash)

  # Re-org the safe/head blocks to point to the alternative side chain
  let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetpayload: proc(): bool =
      for p in shadow.payloads:
        let version = env.engine.version(p.timestamp)
        let r = env.engine.client.newPayload(version, p)
        r.expectStatusEither([PayloadExecutionStatus.valid, PayloadExecutionStatus.accepted])

      let fcu = ForkchoiceStateV1(
        headBlockHash:      shadow.payloads[1].blockHash,
        safeBlockHash:      shadow.payloads[0].blockHash,
        finalizedBlockHash: env.clMock.executedPayloadHistory[1].blockHash,
      )

      let version = env.engine.version(shadow.payloads[1].timestamp)
      let r = env.engine.client.forkchoiceUpdated(version, fcu)
      r.expectPayloadStatus(PayloadExecutionStatus.valid)

      let head = env.engine.client.namedHeader(Head)
      head.expectHash(ethHash shadow.payloads[1].blockHash)

      let safe = env.engine.client.namedHeader(Safe)
      safe.expectHash(ethHash shadow.payloads[0].blockHash)

      let finalized = env.engine.client.namedHeader(Finalized)
      finalized.expectHash(ethHash env.clMock.executedPayloadHistory[1].blockHash)

      return true
  ))

  testCond pbRes
  return true

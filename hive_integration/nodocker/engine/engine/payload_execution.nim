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
  ./engine_spec

type
  ReExecutePayloadTest* = ref object of EngineSpec
    payloadCount*: int

method withMainFork(cs: ReExecutePayloadTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ReExecutePayloadTest): string =
  "Re-Execute Payload"

# Consecutive Payload Execution: Secondary client should be able to set the forkchoiceUpdated to payloads received consecutively
method execute(cs: ReExecutePayloadTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # How many Payloads we are going to re-execute
  let payloadReExecCount = if cs.payloadCount > 0: cs.payloadCount
                           else: 10
  # Create those blocks
  let pbRes = env.clMock.produceBlocks(payloadReExecCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send at least one transaction per payload
      _, err = env.sendNextTx(
        env.clMock.nextBlockProducer,
        BaseTx(
          txType:     cs.txType,
          gasLimit:   75000,
        ),
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", t.TestName, err)
      )
    ),
    onGetPayload: proc(): bool =
      # Check that the transaction was included
      if len(env.clMock.latestPayloadBuilt.transactions) == 0 (
        fatal "Client failed to include the expected transaction in payload built", t.TestName)
      )
    ),
  ))

  # Re-execute the payloads
  r = env.engine.client.blockNumber()
  r.expectNoError()
  lastBlock = r.blockNumber
  info "Started re-executing payloads at block: %v", t.TestName, lastBlock)

  for i = lastBlock - uint64(payloadReExecCount) + 1; i <= lastBlock; i++ (
    payload, found = env.clMock.executedPayloadHistory[i]
    if !found (
      fatal "(test issue) Payload with index %d does not exist", i)
    )

    r = env.engine.client.newPayload(payload)
    r.expectStatus(PayloadExecutionStatus.valid)
    r.expectLatestValidHash(payload.blockHash)
  )
)

type
  InOrderPayloadExecutionTest* = ref object of EngineSpec

method withMainFork(cs: InOrderPayloadExecutionTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InOrderPayloadExecutionTest): string =
  "In-Order Consecutive Payload Execution"

# Consecutive Payload Execution: Secondary client should be able to set the forkchoiceUpdated to payloads received consecutively
method execute(cs: InOrderPayloadExecutionTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Send a single block to allow sending newer transaction types on the payloads
  env.clMock.produceSingleBlock(BlockProcessCallbacks())

  # First prepare payloads on a first client, which will also contain multiple transactions

  # We will be also verifying that the transactions are correctly interpreted in the canonical chain,
  # prepare a random account to receive funds.
  recipient = EthAddress.randomBytes()
  amountPerTx = big.NewInt(1000)
  txPerPayload = 20
  payloadCount = 10
  txsIncluded = 0

  env.clMock.produceBlocks(payloadCount, BlockProcessCallbacks(
    # We send the transactions after we got the Payload ID, before the CLMocker gets the prepared Payload
    onPayloadProducerSelected: proc(): bool =
      _, err = env.sendNextTxs(
        env.clMock.nextBlockProducer,
        BaseTx(
          recipient:  &recipient,
          amount:     amountPerTx,
          txType:     cs.txType,
          gasLimit:   75000,
        ),
        uint64(txPerPayload),
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", t.TestName, err)
      )
    ),
    onGetPayload: proc(): bool =
      if len(env.clMock.latestPayloadBuilt.Transactions) < (txPerPayload / 2) (
        fatal "Client failed to include all the expected transactions in payload built: %d < %d", t.TestName, len(env.clMock.latestPayloadBuilt.Transactions), (txPerPayload / 2))
      )
      txsIncluded += len(env.clMock.latestPayloadBuilt.Transactions)
    ),
  ))

  expectedBalance = amountPerTx.Mul(amountPerTx, big.NewInt(int64(txsIncluded)))

  # Check balance on this first client
  r = env.engine.client.balanceAt(recipient, nil)
  r.expectBalanceEqual(expectedBalance)

  # Start a second client to send newPayload consecutively without fcU
  let sec = env.addEngine(false, false)

  # Send the forkchoiceUpdated with the latestExecutedPayload hash, we should get SYNCING back
  fcU = ForkchoiceStateV1(
    headblockHash:      env.clMock.latestExecutedPayload.blockHash,
    safeblockHash:      env.clMock.latestExecutedPayload.blockHash,
    finalizedblockHash: env.clMock.latestExecutedPayload.blockHash,
  )

  s = sec.client.forkchoiceUpdated(fcU, nil, env.clMock.latestExecutedPayload.timestamp)
  s.expectPayloadStatus(PayloadExecutionStatus.syncing)
  s.expectLatestValidHash(nil)
  s.ExpectNoValidationError()

  # Send all the payloads in the increasing order
  for k = env.clMock.firstPoSBlockNumber.Uint64(); k <= env.clMock.latestExecutedPayload.blockNumber; k++ (
    payload = env.clMock.executedPayloadHistory[k]

    s = sec.client.newPayload(payload)
    s.expectStatus(PayloadExecutionStatus.valid)
    s.expectLatestValidHash(payload.blockHash)

  )

  s = sec.client.forkchoiceUpdated(fcU, nil, env.clMock.latestExecutedPayload.timestamp)
  s.expectPayloadStatus(PayloadExecutionStatus.valid)
  s.expectLatestValidHash(fcU.headblockHash)
  s.ExpectNoValidationError()

  # At this point we should have our funded account balance equal to the expected value.
  q = sec.client.balanceAt(recipient, nil)
  q.expectBalanceEqual(expectedBalance)

  # Add the client to the CLMocker
  env.clMock.addEngine(secondaryClient)

  # Produce a single block on top of the canonical chain, all clients must accept this
  env.clMock.produceSingleBlock(BlockProcessCallbacks())

  # Head must point to the latest produced payload
  p = sec.client.TestHeaderByNumber(nil)
  p.expectHash(env.clMock.latestExecutedPayload.blockHash)
)

type
  MultiplePayloadsExtendingCanonicalChainTest* = ref object of EngineSpec
    # How many parallel payloads to execute
    payloadCount*: int
    # If set to true, the head will be set to the first payload executed by the client
    # If set to false, the head will be set to the latest payload executed by the client
    setHeadToFirstPayloadReceived*: bool

method withMainFork(cs: MultiplePayloadsExtendingCanonicalChainTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: MultiplePayloadsExtendingCanonicalChainTest): string =
  name = "Multiple New Payloads Extending Canonical Chain"
  if s.SetHeadToFirstPayloadReceived (
    name += " (FcU to first payload received)"
  )
  return name
)

# Consecutive Payload Execution: Secondary client should be able to set the forkchoiceUpdated to payloads received consecutively
method execute(cs: MultiplePayloadsExtendingCanonicalChainTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  env.clMock.produceBlocks(5, BlockProcessCallbacks())

  callbacks = BlockProcessCallbacks(
    # We send the transactions after we got the Payload ID, before the CLMocker gets the prepared Payload
    onPayloadProducerSelected: proc(): bool =
      let recipient = EthAddress.randomBytes()
      _, err = env.sendNextTx(
        env.clMock.nextBlockProducer,
        BaseTx(
          recipient:  &recipient,
          txType:     cs.txType,
          gasLimit:   75000,
        ),
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", t.TestName, err)
      )
    ),
  )

  reExecFunc = proc(): bool =
    payloadCount = 80
    if cs.payloadCount > 0 (
      payloadCount = cs.payloadCount
    )

    basePayload = env.clMock.latestPayloadBuilt

    # Check that the transaction was included
    if len(basePayload.Transactions) == 0 (
      fatal "Client failed to include the expected transaction in payload built", t.TestName)
    )

    # Fabricate and send multiple new payloads by changing the PrevRandao field
    for i = 0; i < payloadCount; i++ (
      newPrevRandao = common.Hash256.randomBytes()
      customizer = CustomPayloadData(
        prevRandao: &newPrevRandao,
      )
      newPayload, err = customizePayload(basePayload)
      if err != nil (
        fatal "Unable to customize payload %v: %v", t.TestName, i, err)
      )

      r = env.engine.client.newPayload(newPayload)
      r.expectStatus(PayloadExecutionStatus.valid)
      r.expectLatestValidHash(newPayload.blockHash)
    )
  )

  if cs.SetHeadToFirstPayloadReceived (
    # We are going to set the head of the chain to the first payload executed by the client
    # Therefore our re-execution function must be executed after the payload was broadcast
    callbacks.onNewPayloadBroadcast = reExecFunc
  else:
    # Otherwise, we execute the payloads after we get the canonical one so it's
    # executed last
    callbacks.onGetPayload = reExecFunc
  )

  env.clMock.produceSingleBlock(callbacks)
  # At the end the CLMocker continues to try to execute fcU with the original payload, which should not fail
)

type
  NewPayloadOnSyncingClientTest* = ref object of EngineSpec

method withMainFork(cs: NewPayloadOnSyncingClientTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: NewPayloadOnSyncingClientTest): string =
  "Valid NewPayload->ForkchoiceUpdated on Syncing Client"

# Send a valid payload on a client that is currently SYNCING
method execute(cs: NewPayloadOnSyncingClientTest, env: TestEnv): bool =
  var
      # Set a random transaction recipient
  let recipient = EthAddress.randomBytes()
    previousPayload ExecutableData
  sec = env.addEngine()

  # Wait until TTD is reached by all clients
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  env.clMock.produceBlocks(5, BlockProcessCallbacks())



  # Disconnect the first engine client from the CL Mocker and produce a block
  env.clMock.removeEngine(env.engine)
  env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send at least one transaction per payload
      _, err = env.sendNextTx(
        env.clMock.nextBlockProducer,
        BaseTx(
          recipient:  &recipient,
          txType:     cs.txType,
          gasLimit:   75000,
        ),
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", t.TestName, err)
      )
    ),
    onGetPayload: proc(): bool =
      # Check that the transaction was included
      if len(env.clMock.latestPayloadBuilt.Transactions) == 0 (
        fatal "Client failed to include the expected transaction in payload built", t.TestName)
      )
    ),
  ))

  previousPayload = env.clMock.latestPayloadBuilt

  # Send the fcU to set it to syncing mode
  r = env.engine.client.forkchoiceUpdated(env.clMock.latestForkchoice, nil, env.clMock.latestHeader.Time)
  r.expectPayloadStatus(PayloadExecutionStatus.syncing)

  env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send at least one transaction per payload
      _, err = env.sendNextTx(
        env.clMock.nextBlockProducer,
        BaseTx(
          recipient:  &recipient,
          txType:     cs.txType,
          gasLimit:   75000,
        ),
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", t.TestName, err)
      )
    ),
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Send the new payload from the second client to the first, it won't be able to validate it
      r = env.engine.client.newPayload(env.clMock.latestPayloadBuilt)
      r.expectStatusEither(PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing)
      r.expectLatestValidHash(nil)

      # Send the forkchoiceUpdated with a reference to the valid payload on the SYNCING client.
      var (
        random                = common.Hash256()
        suggestedFeeRecipient = common.Address()
      )
      payloadAttributesCustomizer = &BasePayloadAttributesCustomizer(
        Random:                &random,
        SuggestedFeerecipient: &suggestedFeeRecipient,
      )
      newPayloadAttributes, err = payloadAttributesCustomizer.GetPayloadAttributes(env.clMock.latestPayloadAttributes)
      if err != nil (
        fatal "Unable to customize payload attributes: %v", t.TestName, err)
      )
      s = env.engine.client.forkchoiceUpdated(ForkchoiceStateV1(
        headblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        safeblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        finalizedblockHash: env.clMock.latestPayloadBuilt.blockHash,
      ), newPayloadAttributes, env.clMock.latestPayloadBuilt.timestamp)
      s.expectPayloadStatus(PayloadExecutionStatus.syncing)

      # Send the previous payload to be able to continue
      p = env.engine.client.newPayload(previousPayload)
      p.expectStatus(PayloadExecutionStatus.valid)
      p.expectLatestValidHash(previousPayload.blockHash)

      # Send the new payload again

      p = env.engine.client.newPayload(env.clMock.latestPayloadBuilt)
      p.expectStatus(PayloadExecutionStatus.valid)
      p.expectLatestValidHash(env.clMock.latestPayloadBuilt.blockHash)

      s = env.engine.client.forkchoiceUpdated(ForkchoiceStateV1(
        headblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        safeblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        finalizedblockHash: env.clMock.latestPayloadBuilt.blockHash,
      ), nil, env.clMock.latestPayloadBuilt.timestamp)
      s.expectPayloadStatus(PayloadExecutionStatus.valid)

    return true
  ))

  testCond pbRes
  return true

type
  NewPayloadWithMissingFcUTest* = ref object of EngineSpec

method withMainFork(cs: NewPayloadWithMissingFcUTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: NewPayloadWithMissingFcUTest): string =
  "NewPayload with Missing ForkchoiceUpdated"

# Send a valid `newPayload` in correct order but skip `forkchoiceUpdated` until the last payload
method execute(cs: NewPayloadWithMissingFcUTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Get last genesis block hash
  genesisHash = env.engine.client.latestHeader().Header.Hash()

  # Produce blocks on the main client, these payloads will be replayed on the secondary client.
  env.clMock.produceBlocks(5, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      var recipient common.Address
      randomBytes(recipient[:])
      # Send at least one transaction per payload
      _, err = env.sendNextTx(
        env.clMock.nextBlockProducer,
        BaseTx(
          recipient:  &recipient,
          txType:     cs.txType,
          gasLimit:   75000,
        ),
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", t.TestName, err)
      )
    ),
    onGetPayload: proc(): bool =
      # Check that the transaction was included
      if len(env.clMock.latestPayloadBuilt.Transactions) == 0 (
        fatal "Client failed to include the expected transaction in payload built", t.TestName)
      )
    ),
  ))

  var sec = env.addEngine()

  # Send each payload in the correct order but skip the ForkchoiceUpdated for each
  for i = env.clMock.firstPoSBlockNumber.Uint64(); i <= env.clMock.latestHeadNumber.Uint64(); i++ (
    payload = env.clMock.executedPayloadHistory[i]
    p = sec.newPayload(payload)
    p.expectStatus(PayloadExecutionStatus.valid)
    p.expectLatestValidHash(payload.blockHash)
  )

  # Verify that at this point, the client's head still points to the last non-PoS block
  r = sec.latestHeader()
  r.expectHash(genesisHash)

  # Verify that the head correctly changes after the last ForkchoiceUpdated
  fcU = ForkchoiceStateV1(
    headblockHash:      env.clMock.executedPayloadHistory[env.clMock.latestHeadNumber.Uint64()].blockHash,
    safeblockHash:      env.clMock.executedPayloadHistory[env.clMock.latestHeadNumber.Uint64()-1].blockHash,
    finalizedblockHash: env.clMock.executedPayloadHistory[env.clMock.latestHeadNumber.Uint64()-2].blockHash,
  )
  p = sec.forkchoiceUpdated(fcU, nil, env.clMock.latestHeader.Time)
  p.expectPayloadStatus(PayloadExecutionStatus.valid)
  p.expectLatestValidHash(fcU.headblockHash)

  # Now the head should've changed to the latest PoS block
  s = sec.latestHeader()
  s.expectHash(fcU.headblockHash)
)

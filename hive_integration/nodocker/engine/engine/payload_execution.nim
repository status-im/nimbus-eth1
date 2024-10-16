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
  std/strutils,
  eth/common,
  chronicles,
  ../cancun/customizer,
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
      let tc = BaseTx(
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let ok = env.sendNextTx(env.clMock.nextBlockProducer, tc)
      testCond ok:
        fatal "Error trying to send transaction"
      return true
    ,
    onGetPayload: proc(): bool =
      # Check that the transaction was included
      testCond len(env.clMock.latestPayloadBuilt.transactions) != 0:
        fatal "Client failed to include the expected transaction in payload built"
      return true
  ))

  testCond pbRes

  # Re-execute the payloads
  let r = env.engine.client.blockNumber()
  r.expectNoError()
  let lastBlock = r.get
  info "Started re-executing payloads at block", number=lastBlock

  let start = lastBlock - uint64(payloadReExecCount) + 1

  for i in start..lastBlock:
    doAssert env.clMock.executedPayloadHistory.hasKey(i)
    let payload = env.clMock.executedPayloadHistory[i]
    let r = env.engine.client.newPayload(payload)
    r.expectStatus(PayloadExecutionStatus.valid)
    r.expectLatestValidHash(payload.blockHash)

  return true

type
  InOrderPayloadExecutionTest* = ref object of EngineSpec
  Shadow = ref object
    recipient: Address
    amountPerTx: UInt256
    txPerPayload: int
    payloadCount: int
    txsIncluded: int

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
  testCond env.clMock.produceSingleBlock(BlockProcessCallbacks())

  # First prepare payloads on a first client, which will also contain multiple transactions

  # We will be also verifying that the transactions are correctly interpreted in the canonical chain,
  # prepare a random account to receive funds.
  var shadow = Shadow(
    recipient: Address.randomBytes(),
    amountPerTx: 1000.u256,
    txPerPayload: 20,
    payloadCount: 10,
    txsIncluded: 0,
  )

  let pbRes = env.clMock.produceBlocks(shadow.payloadCount, BlockProcessCallbacks(
    # We send the transactions after we got the Payload ID, before the CLMocker gets the prepared Payload
    onPayloadProducerSelected: proc(): bool =
      let tc = BaseTx(
        recipient:  Opt.some(shadow.recipient),
        amount:     shadow.amountPerTx,
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let ok = env.sendNextTxs(env.clMock.nextBlockProducer, tc, shadow.txPerPayload)
      testCond ok:
        fatal "Error trying to send transaction"
      return true
    ,
    onGetPayload: proc(): bool =
      if len(env.clMock.latestPayloadBuilt.transactions) < (shadow.txPerPayload div 2):
        fatal "Client failed to include all the expected transactions in payload built"

      shadow.txsIncluded += len(env.clMock.latestPayloadBuilt.transactions)
      return true
  ))

  testCond pbRes
  let expectedBalance = shadow.amountPerTx * shadow.txsIncluded.u256

  # Check balance on this first client
  let r = env.engine.client.balanceAt(shadow.recipient)
  r.expectBalanceEqual(expectedBalance)

  # Start a second client to send newPayload consecutively without fcU
  let sec = env.addEngine(false, false)

  # Send the forkchoiceUpdated with the latestExecutedPayload hash, we should get SYNCING back
  let fcU = ForkchoiceStateV1(
    headblockHash:      env.clMock.latestExecutedPayload.blockHash,
    safeblockHash:      env.clMock.latestExecutedPayload.blockHash,
    finalizedblockHash: env.clMock.latestExecutedPayload.blockHash,
  )

  var version = sec.version(env.clMock.latestExecutedPayload.timestamp)
  var s = sec.client.forkchoiceUpdated(version, fcU)
  s.expectPayloadStatus(PayloadExecutionStatus.syncing)
  s.expectLatestValidHash()
  s.expectNoValidationError()

  # Send all the payloads in the increasing order
  let start = env.clMock.firstPoSBlockNumber.get
  for k in start..env.clMock.latestExecutedPayload.blockNumber.uint64:
    let payload = env.clMock.executedPayloadHistory[k]
    let s = sec.client.newPayload(payload)
    s.expectStatus(PayloadExecutionStatus.valid)
    s.expectLatestValidHash(payload.blockHash)

  version = sec.version(env.clMock.latestExecutedPayload.timestamp)
  s = sec.client.forkchoiceUpdated(version, fcU)
  s.expectPayloadStatus(PayloadExecutionStatus.valid)
  s.expectLatestValidHash(fcU.headblockHash)
  s.expectNoValidationError()

  # At this point we should have our funded account balance equal to the expected value.
  let q = sec.client.balanceAt(shadow.recipient)
  q.expectBalanceEqual(expectedBalance)

  # Add the client to the CLMocker
  env.clMock.addEngine(sec)

  # Produce a single block on top of the canonical chain, all clients must accept this
  testCond env.clMock.produceSingleBlock(BlockProcessCallbacks())

  # Head must point to the latest produced payload
  let p = sec.client.latestHeader()
  p.expectHash(env.clMock.latestExecutedPayload.blockHash)
  return true

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
  var name = "Multiple New Payloads Extending Canonical Chain"
  if cs.setHeadToFirstPayloadReceived:
    name.add " (FcU to first payload received)"
  name

# Consecutive Payload Execution: Secondary client should be able to set the forkchoiceUpdated to payloads received consecutively
method execute(cs: MultiplePayloadsExtendingCanonicalChainTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  var callbacks = BlockProcessCallbacks(
    # We send the transactions after we got the Payload ID, before the CLMocker gets the prepared Payload
    onPayloadProducerSelected: proc(): bool =
      let recipient = Address.randomBytes()
      let tc = BaseTx(
        recipient:  Opt.some(recipient),
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let ok = env.sendNextTx(env.clMock.nextBlockProducer, tc)
      testCond ok:
        fatal "Error trying to send transaction"
      return true
  )

  let reExecFunc = proc(): bool {.gcsafe.} =
    var payloadCount = 80
    if cs.payloadCount > 0:
      payloadCount = cs.payloadCount

    let basePayload = env.clMock.latestExecutableData

    # Check that the transaction was included
    testCond len(basePayload.basePayload.transactions) > 0:
      fatal "Client failed to include the expected transaction in payload built"

    # Fabricate and send multiple new payloads by changing the PrevRandao field
    for i in 0..<payloadCount:
      let newPrevRandao = Hash32.randomBytes()
      let customizer = CustomPayloadData(
        prevRandao: Opt.some(newPrevRandao),
      )
      let newPayload = customizer.customizePayload(basePayload)
      let version = env.engine.version(newPayload.timestamp)
      let r = env.engine.client.newPayload(version, newPayload)
      r.expectStatus(PayloadExecutionStatus.valid)
      r.expectLatestValidHash(newPayload.blockHash)
    return true

  if cs.setHeadToFirstPayloadReceived:
    # We are going to set the head of the chain to the first payload executed by the client
    # Therefore our re-execution function must be executed after the payload was broadcast
    callbacks.onNewPayloadBroadcast = reExecFunc
  else:
    # Otherwise, we execute the payloads after we get the canonical one so it's
    # executed last
    callbacks.onGetPayload = reExecFunc

  testCond env.clMock.produceSingleBlock(callbacks)
  # At the end the CLMocker continues to try to execute fcU with the original payload, which should not fail
  return true

type
  NewPayloadOnSyncingClientTest* = ref object of EngineSpec

  Shadow2 = ref object
    recipient: Address
    previousPayload: ExecutionPayload

method withMainFork(cs: NewPayloadOnSyncingClientTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: NewPayloadOnSyncingClientTest): string =
  "Valid NewPayload->ForkchoiceUpdated on Syncing Client"

# Send a valid payload on a client that is currently SYNCING
method execute(cs: NewPayloadOnSyncingClientTest, env: TestEnv): bool =
  var shadow = Shadow2(
    # Set a random transaction recipient
    recipient: Address.randomBytes(),
  )

  discard env.addEngine()

  # Wait until TTD is reached by all clients
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Disconnect the first engine client from the CL Mocker and produce a block
  env.clMock.removeEngine(env.engine)
  var pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send at least one transaction per payload
      let tc = BaseTx(
        recipient:  Opt.some(shadow.recipient),
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let ok = env.sendNextTx(env.clMock.nextBlockProducer, tc)
      testCond ok:
        fatal "Error trying to send transaction"
      return true
    ,
    onGetPayload: proc(): bool =
      # Check that the transaction was included
      testCond len(env.clMock.latestPayloadBuilt.transactions) > 0:
        fatal "Client failed to include the expected transaction in payload built"
      return true
  ))
  testCond true
  shadow.previousPayload = env.clMock.latestPayloadBuilt

  # Send the fcU to set it to syncing mode
  let version = env.engine.version(env.clMock.latestHeader.timestamp)
  let r = env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice)
  r.expectPayloadStatus(PayloadExecutionStatus.syncing)

  pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send at least one transaction per payload
      let tc = BaseTx(
        recipient:  Opt.some(shadow.recipient),
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let ok = env.sendNextTx(env.clMock.nextBlockProducer, tc)
      testCond ok:
        fatal "Error trying to send transaction"
      return true
    ,
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Send the new payload from the second client to the first, it won't be able to validate it
      let r = env.engine.client.newPayload(env.clMock.latestPayloadBuilt)
      r.expectStatusEither([PayloadExecutionStatus.accepted, PayloadExecutionStatus.syncing])
      r.expectLatestValidHash()

      # Send the forkchoiceUpdated with a reference to the valid payload on the SYNCING client.
      var
        random                = default(Hash32)
        suggestedFeeRecipient = default(Address)

      let customizer = BasePayloadAttributesCustomizer(
        prevRandao: Opt.some(random),
        suggestedFeerecipient: Opt.some(suggestedFeeRecipient),
      )

      let newAttr = customizer.getPayloadAttributes(env.clMock.latestPayloadAttributes)
      var fcu = ForkchoiceStateV1(
        headblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        safeblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        finalizedblockHash: env.clMock.latestPayloadBuilt.blockHash,
      )

      var version = env.engine.version(env.clMock.latestPayloadBuilt.timestamp)
      var s = env.engine.client.forkchoiceUpdated(version, fcu, Opt.some(newAttr))
      s.expectPayloadStatus(PayloadExecutionStatus.syncing)

      # Send the previous payload to be able to continue
      var p = env.engine.client.newPayload(shadow.previousPayload)
      p.expectStatus(PayloadExecutionStatus.valid)
      p.expectLatestValidHash(shadow.previousPayload.blockHash)

      # Send the new payload again

      p = env.engine.client.newPayload(env.clMock.latestPayloadBuilt)
      p.expectStatus(PayloadExecutionStatus.valid)
      p.expectLatestValidHash(env.clMock.latestPayloadBuilt.blockHash)

      fcu = ForkchoiceStateV1(
        headblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        safeblockHash:      env.clMock.latestPayloadBuilt.blockHash,
        finalizedblockHash: env.clMock.latestPayloadBuilt.blockHash,
      )
      version = env.engine.version(env.clMock.latestPayloadBuilt.timestamp)
      s = env.engine.client.forkchoiceUpdated(version, fcu)
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
  let res = env.engine.client.latestHeader()
  let genesisHash = res.get.blockHash

  # Produce blocks on the main client, these payloads will be replayed on the secondary client.
  let pbRes = env.clMock.produceBlocks(5, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      let recipient = Address.randomBytes()
      let tc = BaseTx(
        recipient:  Opt.some(recipient),
        txType:     cs.txType,
        gasLimit:   75000,
      )
      # Send at least one transaction per payload
      let ok = env.sendNextTx(env.clMock.nextBlockProducer, tc)
      testCond ok:
        fatal "Error trying to send transaction"
      return true
    ,
    onGetPayload: proc(): bool =
      # Check that the transaction was included
      testCond len(env.clMock.latestPayloadBuilt.transactions) > 0:
        fatal "Client failed to include the expected transaction in payload built"
      return true
  ))
  testCond pbRes

  var sec = env.addEngine()
  let start = env.clMock.firstPoSBlockNumber.get
  # Send each payload in the correct order but skip the ForkchoiceUpdated for each
  for i in start..env.clMock.latestHeadNumber.uint64:
    let payload = env.clMock.executedPayloadHistory[i]
    let p = sec.client.newPayload(payload)
    p.expectStatus(PayloadExecutionStatus.valid)
    p.expectLatestValidHash(payload.blockHash)

  # Verify that at this point, the client's head still points to the last non-PoS block
  let r = sec.client.latestHeader()
  r.expectHash(genesisHash)

  # Verify that the head correctly changes after the last ForkchoiceUpdated
  let fcU = ForkchoiceStateV1(
    headblockHash:      env.clMock.executedPayloadHistory[env.clMock.latestHeadNumber.uint64].blockHash,
    safeblockHash:      env.clMock.executedPayloadHistory[env.clMock.latestHeadNumber.uint64-1].blockHash,
    finalizedblockHash: env.clMock.executedPayloadHistory[env.clMock.latestHeadNumber.uint64-2].blockHash,
  )
  let version = sec.version(env.clMock.latestHeader.timestamp)
  let p = sec.client.forkchoiceUpdated(version, fcU)
  p.expectPayloadStatus(PayloadExecutionStatus.valid)
  p.expectLatestValidHash(fcU.headblockHash)

  # Now the head should've changed to the latest PoS block
  let s = sec.client.latestHeader()
  s.expectHash(fcU.headblockHash)
  return true

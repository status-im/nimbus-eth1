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
  eth/common/eth_types,
  ./engine/engine_spec,
  ./types,
  ./test_env,
  ./base_spec,
  ./cancun/customizer,
  ../../../nimbus/common/chain_config

import
  ./engine/suggested_fee_recipient,
  ./engine/payload_attributes,
  ./engine/payload_execution,
  ./engine/invalid_ancestor,
  ./engine/invalid_payload,
  ./engine/prev_randao,
  ./engine/payload_id,
  ./engine/forkchoice,
  ./engine/versioning,
  ./engine/bad_hash,
  ./engine/fork_id,
  ./engine/reorg,
  ./engine/misc,
  ./engine/rpc

proc getGenesis(cs: EngineSpec, param: NetworkParams) =
  # Set the terminal total difficulty
  let realTTD = param.genesis.difficulty + cs.ttd.u256
  param.config.terminalTotalDifficulty = Opt.some(realTTD)

  # Set the genesis timestamp if provided
  if cs.genesisTimestamp != 0:
    param.genesis.timestamp = cs.genesisTimestamp.EthTime

proc executeEngineSpec*(ws: BaseSpec): bool =
  let
    cs = EngineSpec(ws)
    forkConfig = ws.getForkConfig()

  if forkConfig.isNil:
    echo "because fork configuration is not possible, skip test: ", cs.getName()
    return true

  let conf = envConfig(forkConfig)
  if ws.getGenesisFn.isNil.not:
    ws.getGenesisFn(ws, conf.networkParams)
  else:
    cs.getGenesis(conf.networkParams)

  let env  = TestEnv.new(conf)
  env.engine.setRealTTD()
  env.setupCLMock()
  if cs.enableConfigureCLMock:
    cs.configureCLMock(env.clMock)
  result = cs.execute(env)
  env.close()

# Execution specification reference:
# https://github.com/ethereum/execution-apis/blob/main/src/engine/specification.md

# Register all test combinations for Paris
proc makeEngineTest*(): seq[EngineSpec] =
  # Misc Tests
  # Pre-merge & merge fork occur at block 1, post-merge forks occur at block 2
  result.add NonZeroPreMergeFork(forkHeight: 2)

  # Payload Attributes Tests
  block:
    let list = [
      InvalidPayloadAttributesTest(
        description: "Zero timestamp",
        customizer: BasePayloadAttributesCustomizer(
          timestamp: Opt.some(0'u64),
        ),
      ),
      InvalidPayloadAttributesTest(
        description: "Parent timestamp",
        customizer: TimestampDeltaPayloadAttributesCustomizer(
          timestampDelta: -1,
        ),
      ),
    ]

    for x in list:
      result.add x
      let y = x.clone()
      y.syncing = true
      result.add y

  # Invalid Transaction ChainID Tests
  result.add InvalidTxChainIDTest(
    txType: Opt.some(TxLegacy),
  )

  result.add InvalidTxChainIDTest(
    txType: Opt.some(TxEip1559),
  )

  # Invalid Ancestor Re-Org Tests (Reveal Via NewPayload)
  for invalidIndex in [1, 9, 10]:
    for emptyTxs in [false, true]:
      result.add InvalidMissingAncestorReOrgTest(
        slotsToSafe:       32,
        slotsToFinalized:  64,
        sidechainLength:   10,
        invalidIndex:      invalidIndex,
        invalidField:      InvalidStateRoot,
        emptyTransactions: emptyTxs,
        enableConfigureCLMock: true
      )

  # Invalid Payload Tests
  const
    invalidPayloadBlockFields = [
      InvalidParentHash,
      InvalidStateRoot,
      InvalidReceiptsRoot,
      InvalidNumber,
      InvalidGasLimit,
      InvalidGasUsed,
      InvalidTimestamp,
      InvalidPrevRandao,
      RemoveTransaction,
    ]

  for invalidField in invalidPayloadBlockFields:
    for syncing in [false, true]:
     if invalidField == InvalidStateRoot:
       result.add InvalidPayloadTestCase(
          invalidField:      invalidField,
          syncing:           syncing,
          emptyTransactions: true,
       )

     result.add InvalidPayloadTestCase(
        invalidField: invalidField,
        syncing:      syncing,
     )

  # Register bad hash tests
  for syncing in [false, true]:
    for sidechain in [false, true]:
      result.add BadHashOnNewPayload(
        syncing:   syncing,
        sidechain: sidechain,
      )

  # Parent hash == block hash tests
  result.add ParentHashOnNewPayload(syncing: false)
  result.add ParentHashOnNewPayload(syncing: true)

  result.add PayloadBuildAfterInvalidPayloadTest(
    invalidField: InvalidStateRoot,
  )

  const forkchoiceStateField = [
    HeadBlockHash,
    SafeBlockHash,
    FinalizedBlockHash,
  ]

  # Register ForkchoiceUpdate tests
  for field in forkchoiceStateField:
    result.add InconsistentForkchoiceTest(field: field)
    result.add ForkchoiceUpdatedUnknownBlockHashTest(field: field)

  # PrevRandao opcode tests
  result.add PrevRandaoTransactionTest(
    txType: Opt.some(TxLegacy)
  )

  result.add PrevRandaoTransactionTest(
    txType: Opt.some(TxEip1559),
  )

  # Suggested Fee Recipient Tests
  result.add SuggestedFeeRecipientTest(
    txType: Opt.some(TxLegacy),
    transactionCount: 20,
  )

  result.add SuggestedFeeRecipientTest(
    txType: Opt.some(TxEip1559),
    transactionCount: 20,
  )

  # Payload Execution Tests
  result.add ReExecutePayloadTest()
  result.add InOrderPayloadExecutionTest()
  result.add MultiplePayloadsExtendingCanonicalChainTest(
    setHeadToFirstPayloadReceived: true,
  )

  result.add MultiplePayloadsExtendingCanonicalChainTest(
    setHeadToFirstPayloadReceived: false,
  )

  result.add NewPayloadOnSyncingClientTest()
  result.add NewPayloadWithMissingFcUTest()

  const invalidPayloadBlockField = [
    InvalidTransactionSignature,
    InvalidTransactionNonce,
    InvalidTransactionGasPrice,
    InvalidTransactionGasTipPrice,
    InvalidTransactionGas,
    InvalidTransactionValue,
    InvalidTransactionChainID,
  ]

  # Invalid Transaction Payload Tests
  for invalidField in invalidPayloadBlockField:
    let invalidDetectedOnSync = invalidField == InvalidTransactionChainID
    for syncing in [false, true]:
      if invalidField != InvalidTransactionGasTipPrice:
        for testTxType in [TxLegacy, TxEip1559]:
          result.add InvalidPayloadTestCase(
            txType:                Opt.some(testTxType),
            invalidField:          invalidField,
            syncing:               syncing,
            invalidDetectedOnSync: invalidDetectedOnSync,
          )
      else:
        result.add InvalidPayloadTestCase(
          txType:                Opt.some(TxEip1559),
          invalidField:          invalidField,
          syncing:               syncing,
          invalidDetectedOnSync: invalidDetectedOnSync,
        )

  const payloadAttributesFieldChange = [
    PayloadAttributesIncreaseTimestamp,
    PayloadAttributesRandom,
    PayloadAttributesSuggestedFeeRecipient,
  ]

  # Payload ID Tests
  for payloadAttributeFieldChange in payloadAttributesFieldChange:
    result.add UniquePayloadIDTest(
      fieldModification: payloadAttributeFieldChange,
    )

  # Endpoint Versions Tests
  # Early upgrade of ForkchoiceUpdated when requesting a payload
  result.add ForkchoiceUpdatedOnPayloadRequestTest(
    name: "Early upgrade",
    about: """
      Early upgrade of ForkchoiceUpdated when requesting a payload.
      The test sets the fork height to 1, and the block timestamp increments to 2
      seconds each block.
      CL Mock prepares the payload attributes for the first block, which should contain
      the attributes of the next fork.
      The test then reduces the timestamp by 1, but still uses the next forkchoice updated
      version, which should result in UNSUPPORTED_FORK_ERROR error.
    """,
    forkHeight:              1,
    blockTimestampIncrement: 2,
    forkchoiceUpdatedCustomizer: UpgradeForkchoiceUpdatedVersion(
      expectedError: engineApiUnsupportedFork,
    ),
    payloadAttributescustomizer: TimestampDeltaPayloadAttributesCustomizer(
      timestampDelta:       -1,
    ),
  )

  # Register RPC tests
  let blockStatusRPCCheckType = [
    LatestOnNewPayload,
    LatestOnHeadBlockHash,
    SafeOnSafeBlockHash,
    FinalizedOnFinalizedBlockHash,
  ]

  for field in blockStatusRPCCheckType:
    result.add BlockStatus(checkType: field)

  # Fork ID Tests
  for genesisTimestamp in 0..1:
    for forkTime in 0..2:
      for prevForkTime in 0..forkTime:
        for currentBlock in 0..1:
          result.add ForkIDSpec(
            mainFork:         ForkParis,
            genesistimestamp: genesisTimestamp,
            forkTime:         forkTime.uint64,
            previousForkTime: prevForkTime.uint64,
            produceBlocksBeforePeering: currentBlock,
          )

  # Re-org using the Engine API tests

  # Sidechain re-org tests
  result.add SidechainReOrgTest()
  result.add ReOrgBackFromSyncingTest(
    slotsToSafe:      32,
    slotsToFinalized: 64,
    enableConfigureCLMock: true,
  )

  result.add ReOrgPrevValidatedPayloadOnSideChainTest(
    slotsToSafe:      32,
    slotsToFinalized: 64,
    enableConfigureCLMock: true,
  )

  result.add SafeReOrgToSideChainTest(
    slotsToSafe:      1,
    slotsToFinalized: 2,
    enableConfigureCLMock: true,
  )

  # Re-org a transaction out of a block, or into a new block
  result.add TransactionReOrgTest(
    scenario: TransactionReOrgScenarioReOrgOut,
  )

  result.add TransactionReOrgTest(
    scenario: TransactionReOrgScenarioReOrgDifferentBlock,
  )

  result.add TransactionReOrgTest(
    scenario: TransactionReOrgScenarioNewPayloadOnRevert,
  )

  result.add TransactionReOrgTest(
    scenario: TransactionReOrgScenarioReOrgBackIn,
  )

  # Re-Org back into the canonical chain tests
  result.add ReOrgBackToCanonicalTest(
    slotsToSafe:      10,
    slotsToFinalized: 20,
    timeoutSeconds:   60,
    transactionPerPayload: 1,
    reOrgDepth:            5,
    enableConfigureCLMock: true,
  )

  result.add ReOrgBackToCanonicalTest(
    slotsToSafe:      32,
    slotsToFinalized: 64,
    timeoutSeconds:   120,
    transactionPerPayload:     50,
    reOrgDepth:                10,
    executeSidePayloadOnReOrg: true,
    enableConfigureCLMock: true,
  )

  const
    invalidReorgList = [
      InvalidStateRoot,
      InvalidReceiptsRoot,
      # TODO: InvalidNumber, Test is causing a panic on the secondary node, disabling for now.
      InvalidGasLimit,
      InvalidGasUsed,
      InvalidTimestamp,
      # TODO: InvalidPrevRandao, Test consistently fails with Failed to set invalid block: missing trie node.
      RemoveTransaction,
      InvalidTransactionSignature,
      InvalidTransactionNonce,
      InvalidTransactionGas,
      InvalidTransactionGasPrice,
      InvalidTransactionValue,
      # InvalidOmmers, Unsupported now
    ]

    eightList = [
      InvalidReceiptsRoot,
      InvalidGasLimit,
      InvalidGasUsed,
      InvalidTimestamp,
      InvalidPrevRandao
    ]

  # Invalid Ancestor Re-Org Tests (Reveal Via Sync)
  for invalidField in invalidReorgList:
    for reOrgFromCanonical in [false, true]:
      var invalidIndex = 9
      if invalidField in eightList:
        invalidIndex = 8

      if invalidField == InvalidStateRoot:
        result.add InvalidMissingAncestorReOrgSyncTest(
          timeoutSeconds:   60,
          slotsToSafe:      32,
          slotsToFinalized: 64,
          invalidField:       invalidField,
          reOrgFromCanonical: reOrgFromCanonical,
          emptyTransactions:  true,
          invalidIndex:       invalidIndex,
          enableConfigureCLMock: true,
        )

      result.add InvalidMissingAncestorReOrgSyncTest(
        timeoutSeconds:   60,
        slotsToSafe:      32,
        slotsToFinalized: 64,
        invalidField:       invalidField,
        reOrgFromCanonical: reOrgFromCanonical,
        invalidIndex:       invalidIndex,
        enableConfigureCLMock: true,
      )

proc fillEngineTests(): seq[TestDesc] =
  let list = makeEngineTest()
  for x in list:
    result.add TestDesc(
      name: x.getName(),
      run: executeEngineSpec,
      spec: x,
    )

let engineTestList* = fillEngineTests()

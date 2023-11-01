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
  eth/common/eth_types,
  ./engine/engine_spec,
  ./types,
  ./test_env,
  ./base_spec,
  ./cancun/customizer,
  ../../nimbus/common/chain_config

import
  ./engine/misc,
  ./engine/payload_attributes,
  ./engine/invalid_ancestor,
  ./engine/invalid_payload,
  ./engine/bad_hash

proc getGenesis(cs: EngineSpec, param: NetworkParams) =
  # Set the terminal total difficulty
  let realTTD = param.genesis.difficulty + cs.ttd.u256
  param.config.terminalTotalDifficulty = some(realTTD)
  if param.genesis.difficulty <= realTTD:
    param.config.terminalTotalDifficultyPassed = some(true)

  # Set the genesis timestamp if provided
  if cs.genesisTimestamp != 0:
    param.genesis.timestamp = cs.genesisTimestamp.EthTime

proc specExecute(ws: BaseSpec): bool =
  let
    cs = EngineSpec(ws)
    forkConfig = ws.getForkConfig()

  if forkConfig.isNil:
    echo "because fork configuration is not possible, skip test: ", cs.getName()
    return true

  let conf = envConfig(forkConfig)
  cs.getGenesis(conf.networkParams)
  let env  = TestEnv.new(conf)
  env.engine.setRealTTD()
  env.setupCLMock()
  #cs.configureCLMock(env.clMock)
  result = cs.execute(env)
  env.close()

# Execution specification reference:
# https:#github.com/ethereum/execution-apis/blob/main/src/engine/specification.md

#[var (
  big0      = new(big.Int)
  big1      = u256(1)
  Head      *big.Int # Nil
  Pending   = u256(-2)
  Finalized = u256(-3)
  Safe      = u256(-4)
)
]#

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
          timestamp: some(0'u64),
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
    txType: some(TxLegacy),
  )

  result.add InvalidTxChainIDTest(
    txType: some(TxEip1559),
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

#[
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
        )

      result.add InvalidMissingAncestorReOrgSyncTest(
        timeoutSeconds:   60,
        slotsToSafe:      32,
        slotsToFinalized: 64,
        invalidField:       invalidField,
        reOrgFromCanonical: reOrgFromCanonical,
        invalidIndex:       invalidIndex,
      )
]#
#[
  # Register RPC tests
  for _, field := range []BlockStatusRPCCheckType(
    LatestOnNewPayload,
    LatestOnHeadBlockHash,
    SafeOnSafeBlockHash,
    FinalizedOnFinalizedBlockHash,
  ) (
    result.add BlockStatus(CheckType: field))
  )

  # Register ForkchoiceUpdate tests
  for _, field := range []ForkchoiceStateField(
    HeadBlockHash,
    SafeBlockHash,
    FinalizedBlockHash,
  ) (
    result.add
      InconsistentForkchoiceTest(
        Field: field,
      ),
      ForkchoiceUpdatedUnknownBlockHashTest(
        Field: field,
      ),
    )
  )

  # Payload ID Tests
  for _, payloadAttributeFieldChange := range []PayloadAttributesFieldChange(
    PayloadAttributesIncreaseTimestamp,
    PayloadAttributesRandom,
    PayloadAttributesSuggestedFeeRecipient,
  ) (
    result.add UniquePayloadIDTest(
      FieldModification: payloadAttributeFieldChange,
    ))
  )

  # Endpoint Versions Tests
  # Early upgrade of ForkchoiceUpdated when requesting a payload
  result.add
    ForkchoiceUpdatedOnPayloadRequestTest(
      BaseSpec: test.BaseSpec(
        Name: "Early upgrade",
        About: `
        Early upgrade of ForkchoiceUpdated when requesting a payload.
        The test sets the fork height to 1, and the block timestamp increments to 2
        seconds each block.
        CL Mock prepares the payload attributes for the first block, which should contain
        the attributes of the next fork.
        The test then reduces the timestamp by 1, but still uses the next forkchoice updated
        version, which should result in UNSUPPORTED_FORK_ERROR error.
        `,
        forkHeight:              1,
        BlockTimestampIncrement: 2,
      ),
      ForkchoiceUpdatedcustomizer: UpgradeForkchoiceUpdatedVersion(
        ForkchoiceUpdatedcustomizer: BaseForkchoiceUpdatedCustomizer(
          PayloadAttributescustomizer: TimestampDeltaPayloadAttributesCustomizer(
            PayloadAttributescustomizer: BasePayloadAttributesCustomizer(),
            TimestampDelta:              -1,
          ),
          ExpectedError: globals.UNSUPPORTED_FORK_ERROR,
        ),
      ),
    ),
  )

  # Payload Execution Tests
  result.add
    ReExecutePayloadTest(),
    InOrderPayloadExecutionTest(),
    MultiplePayloadsExtendingCanonicalChainTest(
      SetHeadToFirstPayloadReceived: true,
    ),
    MultiplePayloadsExtendingCanonicalChainTest(
      SetHeadToFirstPayloadReceived: false,
    ),
    NewPayloadOnSyncingClientTest(),
    NewPayloadWithMissingFcUTest(),
  )



  # Invalid Transaction Payload Tests
  for _, invalidField := range []InvalidPayloadBlockField(
    InvalidTransactionSignature,
    InvalidTransactionNonce,
    InvalidTransactionGasPrice,
    InvalidTransactionGasTipPrice,
    InvalidTransactionGas,
    InvalidTransactionValue,
    InvalidTransactionChainID,
  ) (
    invalidDetectedOnSync := invalidField == InvalidTransactionChainID
    for _, syncing in   [false, true) (
      if invalidField != InvalidTransactionGasTipPrice (
        for _, testTxType := range []TestTransactionType(TxLegacy, TxEip1559) (
          result.add InvalidPayloadTestCase(
            BaseSpec: test.BaseSpec(
              txType: some( testTxType,
            ),
            InvalidField:          invalidField,
            Syncing:               syncing,
            InvalidDetectedOnSync: invalidDetectedOnSync,
          ))
        )
      ) else (
        result.add InvalidPayloadTestCase(
          BaseSpec: test.BaseSpec(
            txType: some( TxEip1559,
          ),
          InvalidField:          invalidField,
          Syncing:               syncing,
          InvalidDetectedOnSync: invalidDetectedOnSync,
        ))
      )
    )

  )

  # Re-org using the Engine API tests

  # Sidechain re-org tests
  result.add
    SidechainReOrgTest(),
    ReOrgBackFromSyncingTest(
      BaseSpec: test.BaseSpec(
        slotsToSafe:      u256(32),
        slotsToFinalized: u256(64),
      ),
    ),
    ReOrgPrevValidatedPayloadOnSideChainTest(
      BaseSpec: test.BaseSpec(
        slotsToSafe:      u256(32),
        slotsToFinalized: u256(64),
      ),
    ),
    SafeReOrgToSideChainTest(
      BaseSpec: test.BaseSpec(
        slotsToSafe:      u256(1),
        slotsToFinalized: u256(2),
      ),
    ),
  )

	// Re-org a transaction out of a block, or into a new block
	result.add
		TransactionReOrgTest{
			Scenario: TransactionReOrgScenarioReOrgOut,
		},
		TransactionReOrgTest{
			Scenario: TransactionReOrgScenarioReOrgDifferentBlock,
		},
		TransactionReOrgTest{
			Scenario: TransactionReOrgScenarioNewPayloadOnRevert,
		},
		TransactionReOrgTest{
			Scenario: TransactionReOrgScenarioReOrgBackIn,
		},
	)

  # Re-Org back into the canonical chain tests
  result.add
    ReOrgBackToCanonicalTest(
      BaseSpec: test.BaseSpec(
        slotsToSafe:      u256(10),
        slotsToFinalized: u256(20),
        TimeoutSeconds:   60,
      ),
      TransactionPerPayload: 1,
      ReOrgDepth:            5,
    ),
    ReOrgBackToCanonicalTest(
      BaseSpec: test.BaseSpec(
        slotsToSafe:      u256(32),
        slotsToFinalized: u256(64),
        TimeoutSeconds:   120,
      ),
      TransactionPerPayload:     50,
      ReOrgDepth:                10,
      ExecuteSidePayloadOnReOrg: true,
    ),
  )

  # Suggested Fee Recipient Tests
  result.add
    SuggestedFeeRecipientTest(
      BaseSpec: test.BaseSpec(
        txType: some( TxLegacy,
      ),
      TransactionCount: 20,
    ),
    SuggestedFeeRecipientTest(
      BaseSpec: test.BaseSpec(
        txType: some( TxEip1559,
      ),
      TransactionCount: 20,
    ),
  )

  # PrevRandao opcode tests
  result.add
    PrevRandaoTransactionTest(
      BaseSpec: test.BaseSpec(
        txType: some( TxLegacy,
      ),
    ),
    PrevRandaoTransactionTest(
      BaseSpec: test.BaseSpec(
        txType: some( TxEip1559,
      ),
    ),
  )

  # Fork ID Tests
  for genesisTimestamp := uint64(0); genesisTimestamp <= 1; genesisTimestamp++ (
    for forkTime := uint64(0); forkTime <= 2; forkTime++ (
      for prevForkTime := uint64(0); prevForkTime <= forkTime; prevForkTime++ (
        for currentBlock := 0; currentBlock <= 1; currentBlock++ (
          result.add
            ForkIDSpec(
              BaseSpec: test.BaseSpec(
                MainFork:         config.Paris,
                Genesistimestamp: pUint64(genesisTimestamp),
                ForkTime:         forkTime,
                PreviousForkTime: prevForkTime,
              ),
              ProduceBlocksBeforePeering: currentBlock,
            ),
          )
        )
      )
    )
  )
]#


proc fillEngineTests*(): seq[TestDesc] =
  let list = makeEngineTest()
  for x in list:
    result.add TestDesc(
      name: x.getName(),
      run: specExecute,
      spec: x,
    )

let engineTestList* = fillEngineTests()

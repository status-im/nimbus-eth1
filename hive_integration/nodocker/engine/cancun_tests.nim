import
  std/tables,
  chronos,
  chronicles,
  stew/byteutils,
  ./types,
  ./base_spec,
  ./test_env,
  ./clmock,
  ./cancun/step_desc,
  ./cancun/helpers,
  ./cancun/blobs,
  ../../nimbus/constants,
  ../../nimbus/common/chain_config

import
  ./cancun/step_newpayloads,
  ./cancun/step_sendblobtx

# Precalculate the first data gas cost increase
const
  DATA_GAS_COST_INCREMENT_EXCEED_BLOBS = getMinExcessBlobsForBlobGasPrice(2)
  TARGET_BLOBS_PER_BLOCK = int(TARGET_BLOB_GAS_PER_BLOCK div GAS_PER_BLOB)

proc getGenesis(param: NetworkParams) =
  # Add bytecode pre deploy to the EIP-4788 address.
  param.genesis.alloc[BEACON_ROOTS_ADDRESS] = GenesisAccount(
    balance: 0.u256,
    nonce:   1,
    code:    hexToSeqByte("3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500"),
  )

# Execution specification reference:
# https:#github.com/ethereum/execution-apis/blob/main/src/engine/cancun.md
proc specExecute(ws: BaseSpec): bool =
  ws.mainFork = ForkCancun
  let
    cs = CancunSpec(ws)
    conf = envConfig(ws.getForkConfig())

  getGenesis(conf.networkParams)
  let env  = TestEnv.new(conf)
  env.engine.setRealTTD(0)
  env.setupCLMock()
  ws.configureCLMock(env.clMock)

  testCond waitFor env.clMock.waitForTTD()

  let blobTestCtx = CancunTestContext(
    env: env,
    txPool: TestBlobTxPool(),
  )

  if cs.getPayloadDelay != 0:
    env.clMock.payloadProductionClientDelay = cs.getPayloadDelay

  result = true
  for stepId, step in cs.testSequence:
    echo "INFO: Executing step", stepId+1, ": ", step.description()
    if not step.execute(blobTestCtx):
      fatal "FAIL: Error executing", step=stepId+1
      result = false
      break

  env.close()

# List of all blob tests
let cancunTestList* = [
  TestDesc(
    name: "Blob Transactions On Block 1, Shanghai Genesis",
    about: """
      Tests the Cancun fork since Block 1.

      Verifications performed:
      - Correct implementation of Engine API changes for Cancun:
        - engine_newPayloadV3, engine_forkchoiceUpdatedV3, engine_getPayloadV3
      - Correct implementation of EIP-4844:
        - Blob transaction ordering and inclusion
        - Blob transaction blob gas cost checks
        - Verify Blob bundle on built payload
      - Eth RPC changes for Cancun:
        - Blob fields in eth_getBlockByNumber
        - Beacon root in eth_getBlockByNumber
        - Blob fields in transaction receipts from eth_getTransactionReceipt
      """,
    run: specExecute,
    spec: CancunSpec(
      forkHeight: 1,
      testSequence: @[
        # We are starting at Shanghai genesis so send a couple payloads to reach the fork
        NewPayloads().TestStep,

        # First, we send a couple of blob transactions on genesis,
        # with enough data gas cost to make sure they are included in the first block.
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),

        # We create the first payload, and verify that the blob transactions
        # are included in the payload.
        # We also verify that the blob transactions are included in the blobs bundle.
        #[NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        # Try to increase the data gas cost of the blob transactions
        # by maxing out the number of blobs for the next payloads.
        SendBlobTransactions(
          transactionCount:              DATA_GAS_COST_INCREMENT_EXCEED_BLOBS div (MAX_BLOBS_PER_BLOCK-TARGET_BLOBS_PER_BLOCK) + 1,
          blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),

        # Next payloads will have max data blobs each
        NewPayloads(
          payloadCount:              DATA_GAS_COST_INCREMENT_EXCEED_BLOBS div (MAX_BLOBS_PER_BLOCK - TARGET_BLOBS_PER_BLOCK),
          expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
        ),

        # But there will be an empty payload, since the data gas cost increased
        # and the last blob transaction was not included.
        NewPayloads(
          expectedIncludedBlobCount: 0,
        ),

        # But it will be included in the next payload
        NewPayloads(
          expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
        ),]#
      ]
    )
  ),
]

#[
  TestDesc(
    spec: CancunSpec(


      name: "Blob Transactions On Block 1, Cancun Genesis",
      about: """
      Tests the Cancun fork since genesis.

      Verifications performed:
      * See Blob Transactions On Block 1, Shanghai Genesis
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      NewPayloads(), # Create a single empty payload to push the client through the fork.
      # First, we send a couple of blob transactions on genesis,
      # with enough data gas cost to make sure they are included in the first block.
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),

      # We create the first payload, and verify that the blob transactions
      # are included in the payload.
      # We also verify that the blob transactions are included in the blobs bundle.
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      # Try to increase the data gas cost of the blob transactions
      # by maxing out the number of blobs for the next payloads.
      SendBlobTransactions(
        transactionCount:              DATA_GAS_COST_INCREMENT_EXCEED_BLOBS/(MAX_BLOBS_PER_BLOCK-TARGET_BLOBS_PER_BLOCK) + 1,
        blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),

      # Next payloads will have max data blobs each
      NewPayloads(
        payloadCount:              DATA_GAS_COST_INCREMENT_EXCEED_BLOBS / (MAX_BLOBS_PER_BLOCK - TARGET_BLOBS_PER_BLOCK),
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
      ),

      # But there will be an empty payload, since the data gas cost increased
      # and the last blob transaction was not included.
      NewPayloads(
        expectedIncludedBlobCount: 0,
      ),

      # But it will be included in the next payload
      NewPayloads(
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(


      name: "Blob Transaction Ordering, Single Account",
      about: """
      Send N blob transactions with MAX_BLOBS_PER_BLOCK-1 blobs each,
      using account A.
      Using same account, and an increased nonce from the previously sent
      transactions, send N blob transactions with 1 blob each.
      Verify that the payloads are created with the correct ordering:
       - The first payloads must include the first N blob transactions
       - The last payloads must include the last single-blob transactions
      All transactions have sufficient data gas price to be included any
      of the payloads.
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      # First send the MAX_BLOBS_PER_BLOCK-1 blob transactions.
      SendBlobTransactions(
        transactionCount:              5,
        blobsPerTransaction:           MAX_BLOBS_PER_BLOCK - 1,
        blobTransactionMaxBlobGasCost: u256(100),
      ),
      # Then send the single-blob transactions
      SendBlobTransactions(
        transactionCount:              MAX_BLOBS_PER_BLOCK + 1,
        blobsPerTransaction:           1,
        blobTransactionMaxBlobGasCost: u256(100),
      ),

      # First four payloads have MAX_BLOBS_PER_BLOCK-1 blobs each
      NewPayloads(
        payloadCount:              4,
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK - 1,
      ),

      # The rest of the payloads have full blobs
      NewPayloads(
        payloadCount:              2,
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(


      name: "Blob Transaction Ordering, Single Account 2",
      about: """
      Send N blob transactions with MAX_BLOBS_PER_BLOCK-1 blobs each,
      using account A.
      Using same account, and an increased nonce from the previously sent
      transactions, send a single 2-blob transaction, and send N blob
      transactions with 1 blob each.
      Verify that the payloads are created with the correct ordering:
       - The first payloads must include the first N blob transactions
       - The last payloads must include the rest of the transactions
      All transactions have sufficient data gas price to be included any
      of the payloads.
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      # First send the MAX_BLOBS_PER_BLOCK-1 blob transactions.
      SendBlobTransactions(
        transactionCount:              5,
        blobsPerTransaction:           MAX_BLOBS_PER_BLOCK - 1,
        blobTransactionMaxBlobGasCost: u256(100),
      ),

      # Then send the dual-blob transaction
      SendBlobTransactions(
        transactionCount:              1,
        blobsPerTransaction:           2,
        blobTransactionMaxBlobGasCost: u256(100),
      ),

      # Then send the single-blob transactions
      SendBlobTransactions(
        transactionCount:              MAX_BLOBS_PER_BLOCK - 2,
        blobsPerTransaction:           1,
        blobTransactionMaxBlobGasCost: u256(100),
      ),

      # First five payloads have MAX_BLOBS_PER_BLOCK-1 blobs each
      NewPayloads(
        payloadCount:              5,
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK - 1,
      ),

      # The rest of the payloads have full blobs
      NewPayloads(
        payloadCount:              1,
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(


      name: "Blob Transaction Ordering, Multiple Accounts",
      about: """
      Send N blob transactions with MAX_BLOBS_PER_BLOCK-1 blobs each,
      using account A.
      Send N blob transactions with 1 blob each from account B.
      Verify that the payloads are created with the correct ordering:
       - All payloads must have full blobs.
      All transactions have sufficient data gas price to be included any
      of the payloads.
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      # First send the MAX_BLOBS_PER_BLOCK-1 blob transactions from
      # account A.
      SendBlobTransactions(
        transactionCount:              5,
        blobsPerTransaction:           MAX_BLOBS_PER_BLOCK - 1,
        blobTransactionMaxBlobGasCost: u256(100),
        AccountIndex:                  0,
      ),
      # Then send the single-blob transactions from account B
      SendBlobTransactions(
        transactionCount:              5,
        blobsPerTransaction:           1,
        blobTransactionMaxBlobGasCost: u256(100),
        AccountIndex:                  1,
      ),

      # All payloads have full blobs
      NewPayloads(
        payloadCount:              5,
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(


      name: "Blob Transaction Ordering, Multiple Clients",
      about: """
      Send N blob transactions with MAX_BLOBS_PER_BLOCK-1 blobs each,
      using account A, to client A.
      Send N blob transactions with 1 blob each from account B, to client
      B.
      Verify that the payloads are created with the correct ordering:
       - All payloads must have full blobs.
      All transactions have sufficient data gas price to be included any
      of the payloads.
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      # Start a secondary client to also receive blob transactions
      LaunchClients{
        EngineStarter: hive_rpc.HiveRPCEngineStarter{),
        # Skip adding the second client to the CL Mock to guarantee
        # that all payloads are produced by client A.
        # This is done to not have client B prioritizing single-blob
        # transactions to fill one single payload.
        SkipAddingToCLMock: true,
      ),

      # Create a block without any blobs to get past genesis
      NewPayloads(
        payloadCount:              1,
        expectedIncludedBlobCount: 0,
      ),

      # First send the MAX_BLOBS_PER_BLOCK-1 blob transactions from
      # account A, to client A.
      SendBlobTransactions(
        transactionCount:              5,
        blobsPerTransaction:           MAX_BLOBS_PER_BLOCK - 1,
        blobTransactionMaxBlobGasCost: u256(120),
        AccountIndex:                  0,
        ClientIndex:                   0,
      ),
      # Then send the single-blob transactions from account B, to client
      # B.
      SendBlobTransactions(
        transactionCount:              5,
        blobsPerTransaction:           1,
        blobTransactionMaxBlobGasCost: u256(100),
        AccountIndex:                  1,
        ClientIndex:                   1,
      ),

      # All payloads have full blobs
      NewPayloads(
        payloadCount:              5,
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
        # Wait a bit more on before requesting the built payload from the client
        GetPayloadDelay: 2,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(


      name: "Replace Blob Transactions",
      about: """
      Test sending multiple blob transactions with the same nonce, but
      higher gas tip so the transaction is replaced.
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      # Send multiple blob transactions with the same nonce.
      SendBlobTransactions( # Blob ID 0
        transactionCount:              1,
        blobTransactionMaxBlobGasCost: u256(1),
        BlobTransactionGasFeeCap:      u256(1e9),
        BlobTransactionGasTipCap:      u256(1e9),
      ),
      SendBlobTransactions( # Blob ID 1
        transactionCount:              1,
        blobTransactionMaxBlobGasCost: u256(1e2),
        BlobTransactionGasFeeCap:      u256(1e10),
        BlobTransactionGasTipCap:      u256(1e10),
        ReplaceTransactions:           true,
      ),
      SendBlobTransactions( # Blob ID 2
        transactionCount:              1,
        blobTransactionMaxBlobGasCost: u256(1e3),
        BlobTransactionGasFeeCap:      u256(1e11),
        BlobTransactionGasTipCap:      u256(1e11),
        ReplaceTransactions:           true,
      ),
      SendBlobTransactions( # Blob ID 3
        transactionCount:              1,
        blobTransactionMaxBlobGasCost: u256(1e4),
        BlobTransactionGasFeeCap:      u256(1e12),
        BlobTransactionGasTipCap:      u256(1e12),
        ReplaceTransactions:           true,
      ),

      # We create the first payload, which must contain the blob tx
      # with the higher tip.
      NewPayloads(
        expectedIncludedBlobCount: 1,
        expectedBlobs:             []helper.BlobID{3),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(


      name: "Parallel Blob Transactions",
      about: """
      Test sending multiple blob transactions in parallel from different accounts.

      Verify that a payload is created with the maximum number of blobs.
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      # Send multiple blob transactions with the same nonce.
      ParallelSteps{
        Steps: []TestStep{
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  0,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  1,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  2,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  3,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  4,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  5,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  6,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  7,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  8,
          ),
          SendBlobTransactions(
            transactionCount:              5,
            blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
            blobTransactionMaxBlobGasCost: u256(100),
            AccountIndex:                  9,
          ),
        ),
      ),

      # We create the first payload, which is guaranteed to have the first MAX_BLOBS_PER_BLOCK blobs.
      NewPayloads(
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, MAX_BLOBS_PER_BLOCK),
      ),
    ),
  ),

  # ForkchoiceUpdatedV3 before cancun
  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV3 Set Head to Shanghai Payload, Nil Payload Attributes",
      about: """
      Test sending ForkchoiceUpdatedV3 to set the head of the chain to a Shanghai payload:
      - Send NewPayloadV2 with Shanghai payload on block 1
      - Use ForkchoiceUpdatedV3 to set the head to the payload, with nil payload attributes

      Verify that client returns no error.
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        FcUOnHeadSet: &helper.UpgradeForkchoiceUpdatedVersion{
          ForkchoiceUpdatedCustomizer: &helper.BaseForkchoiceUpdatedCustomizer{),
        ),
        ExpectationDescription: """
        ForkchoiceUpdatedV3 before Cancun returns no error without payload attributes
        """,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV3 To Request Shanghai Payload, Nil Beacon Root",
      about: """
      Test sending ForkchoiceUpdatedV3 to request a Shanghai payload:
      - Payload Attributes uses Shanghai timestamp
      - Payload Attributes' Beacon Root is nil

      Verify that client returns INVALID_PARAMS_ERROR.
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        FcUOnPayloadRequest: &helper.UpgradeForkchoiceUpdatedVersion{
          ForkchoiceUpdatedCustomizer: &helper.BaseForkchoiceUpdatedCustomizer{
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        ForkchoiceUpdatedV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV3 To Request Shanghai Payload, Zero Beacon Root",
      about: """
      Test sending ForkchoiceUpdatedV3 to request a Shanghai payload:
      - Payload Attributes uses Shanghai timestamp
      - Payload Attributes' Beacon Root zero

      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        FcUOnPayloadRequest: &helper.UpgradeForkchoiceUpdatedVersion{
          ForkchoiceUpdatedCustomizer: &helper.BaseForkchoiceUpdatedCustomizer{
            PayloadAttributesCustomizer: &helper.BasePayloadAttributesCustomizer{
              BeaconRoot: &(common.Hash{}),
            ),
            ExpectedError: globals.UNSUPPORTED_FORK_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        ForkchoiceUpdatedV3 before Cancun with beacon root must return UNSUPPORTED_FORK_ERROR (code %d)
        """, *globals.UNSUPPORTED_FORK_ERROR),
      ),
    ),
  ),

  # ForkchoiceUpdatedV2 before cancun with beacon root
  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV2 To Request Shanghai Payload, Zero Beacon Root",
      about: """
      Test sending ForkchoiceUpdatedV2 to request a Cancun payload:
      - Payload Attributes uses Shanghai timestamp
      - Payload Attributes' Beacon Root zero

      Verify that client returns INVALID_PARAMS_ERROR.
      """,
      mainFork:   Cancun,
      forkHeight: 1,
    ),

    testSequence: @[
      NewPayloads(
        FcUOnPayloadRequest: &helper.DowngradeForkchoiceUpdatedVersion{
          ForkchoiceUpdatedCustomizer: &helper.BaseForkchoiceUpdatedCustomizer{
            PayloadAttributesCustomizer: &helper.BasePayloadAttributesCustomizer{
              BeaconRoot: &(common.Hash{}),
            ),
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        ForkchoiceUpdatedV2 before Cancun with beacon root field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),

  # ForkchoiceUpdatedV2 after cancun
  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV2 To Request Cancun Payload, Zero Beacon Root",
      about: """
      Test sending ForkchoiceUpdatedV2 to request a Cancun payload:
      - Payload Attributes uses Cancun timestamp
      - Payload Attributes' Beacon Root zero

      Verify that client returns INVALID_PARAMS_ERROR.
      """,
      mainFork:   Cancun,
      forkHeight: 1,
    ),

    testSequence: @[
      NewPayloads(
        FcUOnPayloadRequest: &helper.DowngradeForkchoiceUpdatedVersion{
          ForkchoiceUpdatedCustomizer: &helper.BaseForkchoiceUpdatedCustomizer{
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        ForkchoiceUpdatedV2 after Cancun with beacon root field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV2 To Request Cancun Payload, Nil Beacon Root",
      about: """
      Test sending ForkchoiceUpdatedV2 to request a Cancun payload:
      - Payload Attributes uses Cancun timestamp
      - Payload Attributes' Beacon Root nil (not provided)

      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
      mainFork:   Cancun,
      forkHeight: 1,
    ),

    testSequence: @[
      NewPayloads(
        FcUOnPayloadRequest: &helper.DowngradeForkchoiceUpdatedVersion{
          ForkchoiceUpdatedCustomizer: &helper.BaseForkchoiceUpdatedCustomizer{
            PayloadAttributesCustomizer: &helper.BasePayloadAttributesCustomizer{
              RemoveBeaconRoot: true,
            ),
            ExpectedError: globals.UNSUPPORTED_FORK_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        ForkchoiceUpdatedV2 after Cancun must return UNSUPPORTED_FORK_ERROR (code %d)
        """, *globals.UNSUPPORTED_FORK_ERROR),
      ),
    ),
  ),

  # ForkchoiceUpdatedV3 with modified BeaconRoot Attribute
  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV3 Modifies Payload ID on Different Beacon Root",
      about: """
      Test requesting a Cancun Payload using ForkchoiceUpdatedV3 twice with the beacon root
      payload attribute as the only change between requests and verify that the payload ID is
      different.
      """,
      mainFork: Cancun,
    ),

    testSequence: @[
      SendBlobTransactions(
        transactionCount:              1,
        blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(100),
      ),
      NewPayloads(
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
        FcUOnPayloadRequest: &helper.BaseForkchoiceUpdatedCustomizer{
          PayloadAttributesCustomizer: &helper.BasePayloadAttributesCustomizer{
            BeaconRoot: &(common.Hash{}),
          ),
        ),
      ),
      SendBlobTransactions(
        transactionCount:              1,
        blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(100),
      ),
      NewPayloads(
        expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
        FcUOnPayloadRequest: &helper.BaseForkchoiceUpdatedCustomizer{
          PayloadAttributesCustomizer: &helper.BasePayloadAttributesCustomizer{
            BeaconRoot: &(common.Hash{1}),
          ),
        ),
      ),
    ),
  ),

  # GetPayloadV3 Before Cancun, Negative Tests
  TestDesc(
    spec: CancunSpec(

      name: "GetPayloadV3 To Request Shanghai Payload",
      about: """
      Test requesting a Shanghai PayloadID using GetPayloadV3.
      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        GetPayloadCustomizer: &helper.UpgradeGetPayloadVersion{
          GetPayloadCustomizer: &helper.BaseGetPayloadCustomizer{
            ExpectedError: globals.UNSUPPORTED_FORK_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        GetPayloadV3 To Request Shanghai Payload must return UNSUPPORTED_FORK_ERROR (code %d)
        """, *globals.UNSUPPORTED_FORK_ERROR),
      ),
    ),
  ),

  # GetPayloadV2 After Cancun, Negative Tests
  TestDesc(
    spec: CancunSpec(

      name: "GetPayloadV2 To Request Cancun Payload",
      about: """
      Test requesting a Cancun PayloadID using GetPayloadV2.
      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
      mainFork:   Cancun,
      forkHeight: 1,
    ),

    testSequence: @[
      NewPayloads(
        GetPayloadCustomizer: &helper.DowngradeGetPayloadVersion{
          GetPayloadCustomizer: &helper.BaseGetPayloadCustomizer{
            ExpectedError: globals.UNSUPPORTED_FORK_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        GetPayloadV2 To Request Cancun Payload must return UNSUPPORTED_FORK_ERROR (code %d)
        """, *globals.UNSUPPORTED_FORK_ERROR),
      ),
    ),
  ),

  # NewPayloadV3 Before Cancun, Negative Tests
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Before Cancun, Nil Data Fields, Nil Versioned Hashes, Nil Beacon Root",
      about: """
      Test sending NewPayloadV3 Before Cancun with:
      - nil ExcessBlobGas
      - nil BlobGasUsed
      - nil Versioned Hashes Array
      - nil Beacon Root

      Verify that client returns INVALID_PARAMS_ERROR
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.UpgradeNewPayloadVersion{
          NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
            payloadCustomizer: CustomPayloadData(
              VersionedHashesCustomizer: &VersionedHashes{
                Blobs: nil,
              ),
            ),
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Before Cancun, Nil ExcessBlobGas, 0x00 BlobGasUsed, Nil Versioned Hashes, Nil Beacon Root",
      about: """
      Test sending NewPayloadV3 Before Cancun with:
      - nil ExcessBlobGas
      - 0x00 BlobGasUsed
      - nil Versioned Hashes Array
      - nil Beacon Root
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.UpgradeNewPayloadVersion{
          NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
            payloadCustomizer: CustomPayloadData(
              BlobGasUsed: pUint64(0),
            ),
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Before Cancun, 0x00 ExcessBlobGas, Nil BlobGasUsed, Nil Versioned Hashes, Nil Beacon Root",
      about: """
      Test sending NewPayloadV3 Before Cancun with:
      - 0x00 ExcessBlobGas
      - nil BlobGasUsed
      - nil Versioned Hashes Array
      - nil Beacon Root
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.UpgradeNewPayloadVersion{
          NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
            payloadCustomizer: CustomPayloadData(
              ExcessBlobGas: pUint64(0),
            ),
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Before Cancun, Nil Data Fields, Empty Array Versioned Hashes, Nil Beacon Root",
      about: """
        Test sending NewPayloadV3 Before Cancun with:
        - nil ExcessBlobGas
        - nil BlobGasUsed
        - Empty Versioned Hashes Array
        - nil Beacon Root
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.UpgradeNewPayloadVersion{
          NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
            payloadCustomizer: CustomPayloadData(
              VersionedHashesCustomizer: &VersionedHashes{
                Blobs: []helper.BlobID{),
              ),
            ),
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Before Cancun, Nil Data Fields, Nil Versioned Hashes, Zero Beacon Root",
      about: """
      Test sending NewPayloadV3 Before Cancun with:
      - nil ExcessBlobGas
      - nil BlobGasUsed
      - nil Versioned Hashes Array
      - Zero Beacon Root
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.UpgradeNewPayloadVersion{
          NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
            payloadCustomizer: CustomPayloadData(
              ParentBeaconRoot: &(common.Hash{}),
            ),
            ExpectedError: globals.INVALID_PARAMS_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Before Cancun, 0x00 Data Fields, Empty Array Versioned Hashes, Zero Beacon Root",
      about: """
      Test sending NewPayloadV3 Before Cancun with:
      - 0x00 ExcessBlobGas
      - 0x00 BlobGasUsed
      - Empty Versioned Hashes Array
      - Zero Beacon Root
      """,
      mainFork:   Cancun,
      forkHeight: 2,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.UpgradeNewPayloadVersion{
          NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
            payloadCustomizer: CustomPayloadData(
              ExcessBlobGas:    pUint64(0),
              BlobGasUsed:      pUint64(0),
              ParentBeaconRoot: &(common.Hash{}),
              VersionedHashesCustomizer: &VersionedHashes{
                Blobs: []helper.BlobID{),
              ),
            ),
            ExpectedError: globals.UNSUPPORTED_FORK_ERROR,
          ),
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 before Cancun with no nil fields must return UNSUPPORTED_FORK_ERROR (code %d)
        """, *globals.UNSUPPORTED_FORK_ERROR),
      ),
    ),
  ),

  # NewPayloadV3 After Cancun, Negative Tests
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 After Cancun, Nil ExcessBlobGas, 0x00 BlobGasUsed, Empty Array Versioned Hashes, Zero Beacon Root",
      about: """
      Test sending NewPayloadV3 After Cancun with:
      - nil ExcessBlobGas
      - 0x00 BlobGasUsed
      - Empty Versioned Hashes Array
      - Zero Beacon Root
      """,
      mainFork:   Cancun,
      forkHeight: 1,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            RemoveExcessBlobGas: true,
          ),
          ExpectedError: globals.INVALID_PARAMS_ERROR,
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 after Cancun with nil ExcessBlobGas must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 After Cancun, 0x00 ExcessBlobGas, Nil BlobGasUsed, Empty Array Versioned Hashes",
      about: """
      Test sending NewPayloadV3 After Cancun with:
      - 0x00 ExcessBlobGas
      - nil BlobGasUsed
      - Empty Versioned Hashes Array
      """,
      mainFork:   Cancun,
      forkHeight: 1,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            RemoveBlobGasUsed: true,
          ),
          ExpectedError: globals.INVALID_PARAMS_ERROR,
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 after Cancun with nil BlobGasUsed must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 After Cancun, 0x00 Blob Fields, Empty Array Versioned Hashes, Nil Beacon Root",
      about: """
      Test sending NewPayloadV3 After Cancun with:
      - 0x00 ExcessBlobGas
      - nil BlobGasUsed
      - Empty Versioned Hashes Array
      """,
      mainFork:   Cancun,
      forkHeight: 1,
    ),

    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            RemoveParentBeaconRoot: true,
          ),
          ExpectedError: globals.INVALID_PARAMS_ERROR,
        ),
        ExpectationDescription: fmt.Sprintf("""
        NewPayloadV3 after Cancun with nil parentBeaconBlockRoot must return INVALID_PARAMS_ERROR (code %d)
        """, *globals.INVALID_PARAMS_ERROR),
      ),
    ),
  ),

  # Fork time tests
  TestDesc(
    spec: CancunSpec(

      name: "ForkchoiceUpdatedV2 then ForkchoiceUpdatedV3 Valid Payload Building Requests",
      about: """
      Test requesting a Shanghai ForkchoiceUpdatedV2 payload followed by a Cancun ForkchoiceUpdatedV3 request.
      Verify that client correctly returns the Cancun payload.
      """,
      mainFork: Cancun,
      # We request two blocks from the client, first on shanghai and then on cancun, both with
      # the same parent.
      # Client must respond correctly to later request.
      forkHeight:              1,
      BlockTimestampIncrement: 2,
    ),

    testSequence: @[
      # First, we send a couple of blob transactions on genesis,
      # with enough data gas cost to make sure they are included in the first block.
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        # This customizer only simulates requesting a Shanghai payload 1 second before cancun.
        # CL Mock will still request the Cancun payload afterwards
        FcUOnPayloadRequest: &helper.BaseForkchoiceUpdatedCustomizer{
          PayloadAttributesCustomizer: &helper.TimestampDeltaPayloadAttributesCustomizer{
            PayloadAttributesCustomizer: &helper.BasePayloadAttributesCustomizer{
              RemoveBeaconRoot: true,
            ),
            TimestampDelta: -1,
          ),
        ),
        ExpectationDescription: """
        ForkchoiceUpdatedV3 must construct transaction with blob payloads even if a ForkchoiceUpdatedV2 was previously requested
        """,
      ),
    ),
  ),

  # Test versioned hashes in Engine API NewPayloadV3
  TestDesc(
    spec: CancunSpec(


      name: "NewPayloadV3 Versioned Hashes, Missing Hash",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is missing one of the hashes.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: getBlobList(0, TARGET_BLOBS_PER_BLOCK-1),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(


      name: "NewPayloadV3 Versioned Hashes, Extra Hash",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is has an extra hash for a blob that is not in the payload.
      """,
      mainFork: Cancun,
    ),
    # TODO: It could be worth it to also test this with a blob that is in the
    # mempool but was not included in the payload.
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: getBlobList(0, TARGET_BLOBS_PER_BLOCK+1),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Out of Order",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is out of order.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: getBlobListByIndex(helper.BlobID(TARGET_BLOBS_PER_BLOCK-1), 0),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Repeated Hash",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob that is repeated in the array.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: append(getBlobList(0, TARGET_BLOBS_PER_BLOCK), helper.BlobID(TARGET_BLOBS_PER_BLOCK-1)),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Incorrect Hash",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob hash that does not belong to any blob contained in the payload.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: append(getBlobList(0, TARGET_BLOBS_PER_BLOCK-1), helper.BlobID(TARGET_BLOBS_PER_BLOCK)),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect hash in list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Incorrect Version",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a single blob that has an incorrect version.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs:        getBlobList(0, TARGET_BLOBS_PER_BLOCK),
              HashVersions: []byte{VERSIONED_HASH_VERSION_KZG, VERSIONED_HASH_VERSION_KZG + 1),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect version in list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Nil Hashes",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is nil, even though the fork has already happened.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: nil,
            ),
          ),
          ExpectedError: globals.INVALID_PARAMS_ERROR,
        ),
        ExpectationDescription: """
        NewPayloadV3 after Cancun with nil VersionedHashes must return INVALID_PARAMS_ERROR (code -32602)
        """,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Empty Hashes",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is empty, even though there are blobs in the payload.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: []helper.BlobID{),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Non-Empty Hashes",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is contains hashes, even though there are no blobs in the payload.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(
        expectedBlobs: []helper.BlobID{),
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: []helper.BlobID{0),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
        ExpectationDescription: """
        NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
        """,
      ),
    ),
  ),

  # Test versioned hashes in Engine API NewPayloadV3 on syncing clients
  TestDesc(
    spec: CancunSpec(


      name: "NewPayloadV3 Versioned Hashes, Missing Hash (Syncing)",
      about: """
        Tests VersionedHashes in Engine API NewPayloadV3 where the array
        is missing one of the hashes.
        """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: getBlobList(0, TARGET_BLOBS_PER_BLOCK-1),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(


      name: "NewPayloadV3 Versioned Hashes, Extra Hash (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is has an extra hash for a blob that is not in the payload.
      """,
      mainFork: Cancun,
    ),
    # TODO: It could be worth it to also test this with a blob that is in the
    # mempool but was not included in the payload.
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: getBlobList(0, TARGET_BLOBS_PER_BLOCK+1),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Out of Order (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is out of order.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),
      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: getBlobListByIndex(helper.BlobID(TARGET_BLOBS_PER_BLOCK-1), 0),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Repeated Hash (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob that is repeated in the array.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: append(getBlobList(0, TARGET_BLOBS_PER_BLOCK), helper.BlobID(TARGET_BLOBS_PER_BLOCK-1)),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Incorrect Hash (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob that is repeated in the array.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: append(getBlobList(0, TARGET_BLOBS_PER_BLOCK-1), helper.BlobID(TARGET_BLOBS_PER_BLOCK)),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Incorrect Version (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a single blob that has an incorrect version.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs:        getBlobList(0, TARGET_BLOBS_PER_BLOCK),
              HashVersions: []byte{VERSIONED_HASH_VERSION_KZG, VERSIONED_HASH_VERSION_KZG + 1),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Nil Hashes (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is nil, even though the fork has already happened.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: nil,
            ),
          ),
          ExpectedError: globals.INVALID_PARAMS_ERROR,
        ),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Empty Hashes (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is empty, even though there are blobs in the payload.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      SendBlobTransactions(
        transactionCount:              TARGET_BLOBS_PER_BLOCK,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      NewPayloads(
        expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
        expectedBlobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: []helper.BlobID{),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),

  TestDesc(
    spec: CancunSpec(

      name: "NewPayloadV3 Versioned Hashes, Non-Empty Hashes (Syncing)",
      about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is contains hashes, even though there are no blobs in the payload.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(), # Send new payload so the parent is unknown to the secondary client
      NewPayloads(
        expectedBlobs: []helper.BlobID{),
      ),

      LaunchClients{
        EngineStarter:            hive_rpc.HiveRPCEngineStarter{),
        SkipAddingToCLMock:       true,
        SkipConnectingToBootnode: true, # So the client is in a perpetual syncing state
      ),
      SendModifiedLatestPayload{
        ClientID: 1,
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            VersionedHashesCustomizer: &VersionedHashes{
              Blobs: []helper.BlobID{0),
            ),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),

  # BlobGasUsed, ExcessBlobGas Negative Tests
  # Most cases are contained in https:#github.com/ethereum/execution-spec-tests/tree/main/tests/cancun/eip4844_blobs
  # and can be executed using """pyspec""" simulator.
  TestDesc(
    spec: CancunSpec(

      name: "Incorrect BlobGasUsed: Non-Zero on Zero Blobs",
      about: """
      Send a payload with zero blobs, but non-zero BlobGasUsed.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            BlobGasUsed: pUint64(1),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),
  TestDesc(
    spec: CancunSpec(


      name: "Incorrect BlobGasUsed: GAS_PER_BLOB on Zero Blobs",
      about: """
      Send a payload with zero blobs, but non-zero BlobGasUsed.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      NewPayloads(
        NewPayloadCustomizer: &helper.BaseNewPayloadVersionCustomizer{
          payloadCustomizer: CustomPayloadData(
            BlobGasUsed: pUint64(cancun.GAS_PER_BLOB),
          ),
          ExpectInvalidStatus: true,
        ),
      ),
    ),
  ),

  # DevP2P tests
  TestDesc(
    spec: CancunSpec(

      name: "Request Blob Pooled Transactions",
      about: """
      Requests blob pooled transactions and verify correct encoding.
      """,
      mainFork: Cancun,
    ),
    testSequence: @[
      # Get past the genesis
      NewPayloads(
        payloadCount: 1,
      ),
      # Send multiple transactions with multiple blobs each
      SendBlobTransactions(
        transactionCount:              1,
        blobTransactionMaxBlobGasCost: u256(1),
      ),
      DevP2PRequestPooledTransactionHash{
        ClientIndex:                 0,
        TransactionIndexes:          []uint64{0),
        WaitForNewPooledTransaction: true,
      ),
    ),
  ),
}

var EngineAPITests []test.Spec

func init() {
  # Append all engine api tests with Cancun as main fork
  for _, test := range suite_engine.Tests {
    Tests = append(Tests, test.WithMainFork(Cancun))
  }

  # Cancun specific variants for pre-existing tests
  baseSpec := test.BaseSpec{
    mainFork: Cancun,
  }
  onlyBlobTxsSpec := test.BaseSpec{
    mainFork:            Cancun,
    TestTransactionType: helper.BlobTxOnly,
  }

  # Payload Attributes
  for _, t := range []suite_engine.InvalidPayloadAttributesTest{
    {
      BaseSpec:    baseSpec,
      Description: "Missing BeaconRoot",
      Customizer: &helper.BasePayloadAttributesCustomizer{
        RemoveBeaconRoot: true,
      ),
      # Error is expected on syncing because V3 checks all fields to be present
      ErrorOnSync: true,
    ),
  } {
    Tests = append(Tests, t)
    t.Syncing = true
    Tests = append(Tests, t)
  }

  # Unique Payload ID Tests
  for _, t := range []suite_engine.PayloadAttributesFieldChange{
    suite_engine.PayloadAttributesParentBeaconRoot,
    # TODO: Remove when withdrawals suite is refactored
    suite_engine.PayloadAttributesAddWithdrawal,
    suite_engine.PayloadAttributesModifyWithdrawalAmount,
    suite_engine.PayloadAttributesModifyWithdrawalIndex,
    suite_engine.PayloadAttributesModifyWithdrawalValidator,
    suite_engine.PayloadAttributesModifyWithdrawalAddress,
    suite_engine.PayloadAttributesRemoveWithdrawal,
  } {
    Tests = append(Tests, suite_engine.UniquePayloadIDTest{
      BaseSpec:          baseSpec,
      FieldModification: t,
    })
  }

  # Invalid Payload Tests
  for _, invalidField := range []helper.InvalidPayloadBlockField{
    helper.InvalidParentBeaconBlockRoot,
    helper.InvalidBlobGasUsed,
    helper.InvalidBlobCountGasUsed,
    helper.InvalidExcessBlobGas,
    helper.InvalidVersionedHashes,
    helper.InvalidVersionedHashesVersion,
    helper.IncompleteVersionedHashes,
    helper.ExtraVersionedHashes,
  } {
    for _, syncing := range []bool{false, true} {
      # Invalidity of payload can be detected even when syncing because the
      # blob gas only depends on the transactions contained.
      invalidDetectedOnSync := (invalidField == helper.InvalidBlobGasUsed ||
        invalidField == helper.InvalidBlobCountGasUsed ||
        invalidField == helper.InvalidVersionedHashes ||
        invalidField == helper.InvalidVersionedHashesVersion ||
        invalidField == helper.IncompleteVersionedHashes ||
        invalidField == helper.ExtraVersionedHashes)

      nilLatestValidHash := (invalidField == helper.InvalidVersionedHashes ||
        invalidField == helper.InvalidVersionedHashesVersion ||
        invalidField == helper.IncompleteVersionedHashes ||
        invalidField == helper.ExtraVersionedHashes)

      Tests = append(Tests, suite_engine.InvalidPayloadTestCase{
        BaseSpec:              onlyBlobTxsSpec,
        InvalidField:          invalidField,
        Syncing:               syncing,
        InvalidDetectedOnSync: invalidDetectedOnSync,
        NilLatestValidHash:    nilLatestValidHash,
      })
    }
  }

  # Invalid Transaction ChainID Tests
  Tests = append(Tests,
    suite_engine.InvalidTxChainIDTest{
      BaseSpec: onlyBlobTxsSpec,
    ),
  )

  Tests = append(Tests, suite_engine.PayloadBuildAfterInvalidPayloadTest{
    BaseSpec:     onlyBlobTxsSpec,
    InvalidField: helper.InvalidParentBeaconBlockRoot,
  })

  # Suggested Fee Recipient Tests (New Transaction Type)
  Tests = append(Tests,
    suite_engine.SuggestedFeeRecipientTest{
      BaseSpec:         onlyBlobTxsSpec,
      transactionCount: 1, # Only one blob tx gets through due to blob gas limit
    ),
  )
  # Prev Randao Tests (New Transaction Type)
  Tests = append(Tests,
    suite_engine.PrevRandaoTransactionTest{
      BaseSpec: onlyBlobTxsSpec,
    ),
  )
}
]#
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
  std/[tables, math, strutils],
  chronos,
  chronicles,
  stew/byteutils,
  eth/common,
  ./types,
  ./base_spec,
  ./test_env,
  ./clmock,
  ./cancun/step_desc,
  ./cancun/helpers,
  ./cancun/blobs,
  ./cancun/customizer,
  ./engine_tests,
  ./engine/engine_spec,
  ../../../nimbus/constants,
  ../../../nimbus/common/chain_config

import
  ./cancun/step_newpayloads,
  ./cancun/step_sendblobtx,
  ./cancun/step_launch_client,
  ./cancun/step_sendmodpayload,
  ./cancun/step_devp2p_pooledtx,
  ./engine/suggested_fee_recipient,
  ./engine/payload_attributes,
  ./engine/invalid_payload,
  ./engine/prev_randao,
  ./engine/payload_id

# Precalculate the first data gas cost increase
const
  DATA_GAS_COST_INCREMENT_EXCEED_BLOBS = getMinExcessBlobsForBlobGasPrice(2).int
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
  let
    cs = CancunSpec(ws)
    conf = envConfig(ws.getForkConfig())

  getGenesis(conf.networkParams)
  let env  = TestEnv.new(conf)
  env.engine.setRealTTD()
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
    echo "INFO: Executing step ", stepId+1, ": ", step.description()
    if not step.execute(blobTestCtx):
      fatal "FAIL: Error executing", step=stepId+1
      result = false
      break

  env.close()

# List of all blob tests
let cancunTestListA* = [
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
      mainFork: ForkCancun,
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
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
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
        ),
      ]
    )
  ),

  TestDesc(
    name: "Blob Transactions On Block 1, Cancun Genesis",
    about: """
      Tests the Cancun fork since genesis.

      Verifications performed:
      * See Blob Transactions On Block 1, Shanghai Genesis
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
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
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
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
        ),
      ]
    ),
  ),

  TestDesc(
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
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
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
      ]
    ),
  ),

  TestDesc(
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
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
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
      ]
    ),
  ),

  TestDesc(
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
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        # First send the MAX_BLOBS_PER_BLOCK-1 blob transactions from
        # account A.
        SendBlobTransactions(
          transactionCount:              5,
          blobsPerTransaction:           MAX_BLOBS_PER_BLOCK - 1,
          blobTransactionMaxBlobGasCost: u256(100),
          accountIndex:                  0,
        ),
        # Then send the single-blob transactions from account B
        SendBlobTransactions(
          transactionCount:              5,
          blobsPerTransaction:           1,
          blobTransactionMaxBlobGasCost: u256(100),
          accountIndex:                  1,
        ),
        # All payloads have full blobs
        NewPayloads(
          payloadCount:              5,
          expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
        ),
      ]
    ),
  ),

  TestDesc(
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
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        # Start a secondary client to also receive blob transactions
        LaunchClients(
          #engineStarter: hive_rpc.HiveRPCEngineStarter{),
          # Skip adding the second client to the CL Mock to guarantee
          # that all payloads are produced by client A.
          # This is done to not have client B prioritizing single-blob
          # transactions to fill one single payload.
          skipAddingToCLMock: true,
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
          accountIndex:                  0,
          clientIndex:                   0,
        ),
        # Then send the single-blob transactions from account B, to client
        # B.
        SendBlobTransactions(
          transactionCount:              5,
          blobsPerTransaction:           1,
          blobTransactionMaxBlobGasCost: u256(100),
          accountIndex:                  1,
          clientIndex:                   1,
        ),

        # All payloads have full blobs
        NewPayloads(
          payloadCount:              5,
          expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
          # Wait a bit more on before requesting the built payload from the client
          getPayloadDelay: 2,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "Replace Blob Transactions",
    about: """
      Test sending multiple blob transactions with the same nonce, but
      higher gas tip so the transaction is replaced.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        # Send multiple blob transactions with the same nonce.
        SendBlobTransactions( # Blob ID 0
          transactionCount:              1,
          blobTransactionMaxBlobGasCost: u256(1),
          blobTransactionGasFeeCap:      GasInt(10 ^ 9),
          blobTransactionGasTipCap:      GasInt(10 ^ 9),
        ),
        SendBlobTransactions( # Blob ID 1
          transactionCount:              1,
          blobTransactionMaxBlobGasCost: u256(10 ^ 2),
          blobTransactionGasFeeCap:      GasInt(10 ^ 10),
          blobTransactionGasTipCap:      GasInt(10 ^ 10),
          replaceTransactions:           true,
        ),
        SendBlobTransactions( # Blob ID 2
          transactionCount:              1,
          blobTransactionMaxBlobGasCost: u256(10 ^ 3),
          blobTransactionGasFeeCap:      GasInt(10 ^ 11),
          blobTransactionGasTipCap:      GasInt(10 ^ 11),
          replaceTransactions:           true,
        ),
        SendBlobTransactions( # Blob ID 3
          transactionCount:              1,
          blobTransactionMaxBlobGasCost: u256(10 ^ 4),
          blobTransactionGasFeeCap:      GasInt(10 ^ 12),
          blobTransactionGasTipCap:      GasInt(10 ^ 12),
          replaceTransactions:           true,
        ),

        # We create the first payload, which must contain the blob tx
        # with the higher tip.
        NewPayloads(
          expectedIncludedBlobCount: 1,
          expectedblobs:             @[BlobID(3)],
        ),
      ]
    ),
  ),

  # ForkchoiceUpdatedV3 before cancun
  TestDesc(
    name: "ForkchoiceUpdatedV3 Set Head to Shanghai Payload, Nil Payload Attributes",
    about: """
      Test sending ForkchoiceUpdatedV3 to set the head of the chain to a Shanghai payload:
      - Send NewPayloadV2 with Shanghai payload on block 1
      - Use ForkchoiceUpdatedV3 to set the head to the payload, with nil payload attributes

      Verify that client returns no error.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          fcUOnHeadSet: UpgradeForkchoiceUpdatedVersion(),
          expectationDescription: """
          ForkchoiceUpdatedV3 before Cancun returns no error without payload attributes
          """,
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "ForkchoiceUpdatedV3 To Request Shanghai Payload, Nil Beacon Root",
    about: """
      Test sending ForkchoiceUpdatedV3 to request a Shanghai payload:
      - Payload Attributes uses Shanghai timestamp
      - Payload Attributes' Beacon Root is nil

      Verify that client returns INVALID_PAYLOAD_ATTRIBUTES.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          fcUOnPayloadRequest: UpgradeForkchoiceUpdatedVersion(
            expectedError: engineApiInvalidPayloadAttributes,
          ),
          expectationDescription: """
          ForkchoiceUpdatedV3 before Cancun with any nil field must return INVALID_PAYLOAD_ATTRIBUTES (code $1)
          """ % [$engineApiInvalidPayloadAttributes],
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "ForkchoiceUpdatedV3 To Request Shanghai Payload, Zero Beacon Root",
    about: """
      Test sending ForkchoiceUpdatedV3 to request a Shanghai payload:
      - Payload Attributes uses Shanghai timestamp
      - Payload Attributes' Beacon Root zero

      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          fcUOnPayloadRequest: UpgradeForkchoiceUpdatedVersion(
            beaconRoot: Opt.some(common.Hash256()),
            expectedError: engineApiUnsupportedFork,
          ),
          expectationDescription: """
          ForkchoiceUpdatedV3 before Cancun with beacon root must return UNSUPPORTED_FORK_ERROR (code $1)
          """ % [$engineApiUnsupportedFork],
        ).TestStep,
      ]
    ),
  ),

  # ForkchoiceUpdatedV2 before cancun with beacon root
  TestDesc(
    name: "ForkchoiceUpdatedV2 To Request Shanghai Payload, Zero Beacon Root",
    about: """
      Test sending ForkchoiceUpdatedV2 to request a Cancun payload:
      - Payload Attributes uses Shanghai timestamp
      - Payload Attributes' Beacon Root zero

      Verify that client returns INVALID_PAYLOAD_ATTRIBUTES.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          fcUOnPayloadRequest: BaseForkchoiceUpdatedCustomizer(
            beaconRoot: Opt.some(common.Hash256()),
            expectedError: engineApiInvalidPayloadAttributes,
          ),
          expectationDescription: """
          ForkchoiceUpdatedV2 before Cancun with beacon root field must return INVALID_PAYLOAD_ATTRIBUTES (code $1)
          """ % [$engineApiInvalidPayloadAttributes],
        ).TestStep,
      ]
    ),
  ),

  # ForkchoiceUpdatedV2 after cancun
  TestDesc(
    name: "ForkchoiceUpdatedV2 To Request Cancun Payload, Zero Beacon Root",
    about: """
      Test sending ForkchoiceUpdatedV2 to request a Cancun payload:
      - Payload Attributes uses Cancun timestamp
      - Payload Attributes' Beacon Root zero

      Verify that client returns INVALID_PAYLOAD_ATTRIBUTES.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 1,
      testSequence: @[
        NewPayloads(
          fcUOnPayloadRequest: DowngradeForkchoiceUpdatedVersion(
            beaconRoot: Opt.some(common.Hash256()),
            expectedError: engineApiInvalidPayloadAttributes,
          ),
          expectationDescription: """
          ForkchoiceUpdatedV2 after Cancun with beacon root field must return INVALID_PAYLOAD_ATTRIBUTES (code $1)
          """ % [$engineApiInvalidPayloadAttributes],
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "ForkchoiceUpdatedV2 To Request Cancun Payload, Nil Beacon Root",
    about: """
      Test sending ForkchoiceUpdatedV2 to request a Cancun payload:
      - Payload Attributes uses Cancun timestamp
      - Payload Attributes' Beacon Root nil (not provided)

      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 1,
      testSequence: @[
        NewPayloads(
          fcUOnPayloadRequest: DowngradeForkchoiceUpdatedVersion(
            removeBeaconRoot: true,
            expectedError: engineApiUnsupportedFork,
          ),
          expectationDescription: """
          ForkchoiceUpdatedV2 after Cancun must return UNSUPPORTED_FORK_ERROR (code $1)
          """ % [$engineApiUnsupportedFork],
        ).TestStep,
      ]
    ),
  ),

  # ForkchoiceUpdatedV3 with modified BeaconRoot Attribute
  TestDesc(
    name: "ForkchoiceUpdatedV3 Modifies Payload ID on Different Beacon Root",
    about: """
      Test requesting a Cancun Payload using ForkchoiceUpdatedV3 twice with the beacon root
      payload attribute as the only change between requests and verify that the payload ID is
      different.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              1,
          blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(100),
        ),
        NewPayloads(
          expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
          fcUOnPayloadRequest: BaseForkchoiceUpdatedCustomizer(
            beaconRoot: Opt.some(common.Hash256()),
          ),
        ),
        SendBlobTransactions(
          transactionCount:              1,
          blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(100),
        ),
        NewPayloads(
          expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
          fcUOnPayloadRequest: BaseForkchoiceUpdatedCustomizer(
             beaconRoot: Opt.some(toHash(1.u256)),
          ),
        ),
      ]
    ),
  ),

  # GetPayloadV3 Before Cancun, Negative Tests
  TestDesc(
    name: "GetPayloadV3 To Request Shanghai Payload",
    about: """
      Test requesting a Shanghai PayloadID using GetPayloadV3.
      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          getPayloadCustomizer: UpgradeGetPayloadVersion(
            expectedError: engineApiUnsupportedFork,
          ),
          expectationDescription: """
          GetPayloadV3 To Request Shanghai Payload must return UNSUPPORTED_FORK_ERROR (code $1)
          """ % [$engineApiUnsupportedFork],
        ).TestStep,
      ]
    ),
  ),

  # GetPayloadV2 After Cancun, Negative Tests
  TestDesc(
    name: "GetPayloadV2 To Request Cancun Payload",
    about: """
      Test requesting a Cancun PayloadID using GetPayloadV2.
      Verify that client returns UNSUPPORTED_FORK_ERROR.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 1,
      testSequence: @[
        NewPayloads(
          getPayloadCustomizer: DowngradeGetPayloadVersion(
            expectedError: engineApiUnsupportedFork,
          ),
          expectationDescription: """
          GetPayloadV2 To Request Cancun Payload must return UNSUPPORTED_FORK_ERROR (code $1)
          """ % [$engineApiUnsupportedFork],
        ).TestStep,
      ]
    ),
  ),

  # NewPayloadV3 Before Cancun, Negative Tests
  TestDesc(
    name: "NewPayloadV3 Before Cancun, Nil Data Fields, Nil Versioned Hashes, Nil Beacon Root",
    about: """
      Test sending NewPayloadV3 Before Cancun with:
      - nil ExcessBlobGas
      - nil BlobGasUsed
      - nil Versioned Hashes Array
      - nil Beacon Root

      Verify that client returns INVALID_PARAMS_ERROR
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: UpgradeNewPayloadVersion(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer()
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Before Cancun, Nil ExcessBlobGas, 0x00 BlobGasUsed, Nil Versioned Hashes, Nil Beacon Root",
    about: """
      Test sending NewPayloadV3 Before Cancun with:
      - nil ExcessBlobGas
      - 0x00 BlobGasUsed
      - nil Versioned Hashes Array
      - nil Beacon Root
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: UpgradeNewPayloadVersion(
            payloadCustomizer: CustomPayloadData(
              blobGasUsed: Opt.some(0'u64),
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Before Cancun, Nil Data Fields, Empty Array Versioned Hashes, Nil Beacon Root",
    about: """
        Test sending NewPayloadV3 Before Cancun with:
        - nil ExcessBlobGas
        - nil BlobGasUsed
        - Empty Versioned Hashes Array
        - nil Beacon Root
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: UpgradeNewPayloadVersion(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(newSeq[BlobID]()),
              ),
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Before Cancun, 0x00 Data Fields, Empty Array Versioned Hashes, Zero Beacon Root",
    about: """
      Test sending NewPayloadV3 Before Cancun with:
      - 0x00 ExcessBlobGas
      - 0x00 BlobGasUsed
      - Empty Versioned Hashes Array
      - Zero Beacon Root
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: UpgradeNewPayloadVersion(
            payloadCustomizer: CustomPayloadData(
              excessBlobGas:    Opt.some(0'u64),
              blobGasUsed:      Opt.some(0'u64),
              parentBeaconRoot: Opt.some(common.Hash256()),
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(newSeq[BlobID]()),
              ),
            ),
            expectedError: engineApiUnsupportedFork,
          ),
          expectationDescription: """
          NewPayloadV3 before Cancun with no nil fields must return UNSUPPORTED_FORK_ERROR (code $1)
          """ % [$engineApiUnsupportedFork],
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 After Cancun, 0x00 Blob Fields, Empty Array Versioned Hashes, Nil Beacon Root",
    about: """
      Test sending NewPayloadV3 After Cancun with:
      - 0x00 ExcessBlobGas
      - nil BlobGasUsed
      - Empty Versioned Hashes Array
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 1,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              removeParentBeaconRoot: true,
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 after Cancun with nil parentBeaconBlockRoot must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  # Fork time tests
  TestDesc(
    name: "ForkchoiceUpdatedV2 then ForkchoiceUpdatedV3 Valid Payload Building Requests",
    about: """
      Test requesting a Shanghai ForkchoiceUpdatedV2 payload followed by a Cancun ForkchoiceUpdatedV3 request.
      Verify that client correctly returns the Cancun payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      # We request two blocks from the client, first on shanghai and then on cancun, both with
      # the same parent.
      # Client must respond correctly to later request.
      forkHeight:              1,
      blockTimestampIncrement: 2,
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
          fcUOnPayloadRequest: TimestampDeltaPayloadAttributesCustomizer(
             removeBeaconRoot: true,
             timestampDelta: -1,
          ),
          expectationDescription: """
          ForkchoiceUpdatedV3 must construct transaction with blob payloads even if a ForkchoiceUpdatedV2 was previously requested
          """,
        ),
      ]
    ),
  ),

  # Test versioned hashes in Engine API NewPayloadV3
  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Missing Hash",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is missing one of the hashes.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK-1)),
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Extra Hash",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is has an extra hash for a blob that is not in the payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      # TODO: It could be worth it to also test this with a blob that is in the
      # mempool but was not included in the payload.
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK+1)),
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Out of Order",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is out of order.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobListByIndex(BlobID(TARGET_BLOBS_PER_BLOCK-1), 0)),
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Repeated Hash",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob that is repeated in the array.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK, BlobID(TARGET_BLOBS_PER_BLOCK-1))),
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Incorrect Hash",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob hash that does not belong to any blob contained in the payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK-1, BlobID(TARGET_BLOBS_PER_BLOCK))),
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect hash in list of versioned hashes must return INVALID status
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Incorrect Version",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a single blob that has an incorrect version.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs:        Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK)),
                hashVersions: @[VERSIONED_HASH_VERSION_KZG.byte, (VERSIONED_HASH_VERSION_KZG + 1).byte],
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect version in list of versioned hashes must return INVALID status
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Nil Hashes",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is nil, even though the fork has already happened.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.none(seq[BlobID]),
              ),
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 after Cancun with nil VersionedHashes must return INVALID_PARAMS_ERROR (code -32602)
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Empty Hashes",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is empty, even though there are blobs in the payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(newSeq[BlobID]()),
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
          """,
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Non-Empty Hashes",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is contains hashes, even though there are no blobs in the payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(
          expectedblobs: @[],
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(@[BlobID(0)]),
              ),
            ),
            expectInvalidStatus: true,
          ),
          expectationDescription: """
          NewPayloadV3 with incorrect list of versioned hashes must return INVALID status
          """,
        ).TestStep,
      ]
    ),
  ),

  # Test versioned hashes in Engine API NewPayloadV3 on syncing clients
  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Missing Hash (Syncing)",
    about: """
        Tests VersionedHashes in Engine API NewPayloadV3 where the array
        is missing one of the hashes.
        """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK-1)),
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Extra Hash (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is has an extra hash for a blob that is not in the payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
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
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK+1)),
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Out of Order (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is out of order.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobListByIndex(BlobID(TARGET_BLOBS_PER_BLOCK-1), 0)),
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Repeated Hash (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob that is repeated in the array.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK, BlobID(TARGET_BLOBS_PER_BLOCK-1))),
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Incorrect Hash (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a blob that is repeated in the array.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
        testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK-1, BlobID(TARGET_BLOBS_PER_BLOCK))),
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Incorrect Version (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      has a single blob that has an incorrect version.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs:        Opt.some(getBlobList(0, TARGET_BLOBS_PER_BLOCK)),
                hashVersions: @[VERSIONED_HASH_VERSION_KZG.byte, (VERSIONED_HASH_VERSION_KZG + 1).byte],
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Nil Hashes (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is nil, even though the fork has already happened.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.none(seq[BlobID]),
              ),
            ),
            expectedError: engineApiInvalidParams,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Empty Hashes (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is empty, even though there are blobs in the payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        SendBlobTransactions(
          transactionCount:              TARGET_BLOBS_PER_BLOCK,
          blobTransactionMaxBlobGasCost: u256(1),
        ),
        NewPayloads(
          expectedIncludedBlobCount: TARGET_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, TARGET_BLOBS_PER_BLOCK),
        ),

        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(newSeq[BlobID]()),
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  TestDesc(
    name: "NewPayloadV3 Versioned Hashes, Non-Empty Hashes (Syncing)",
    about: """
      Tests VersionedHashes in Engine API NewPayloadV3 where the array
      is contains hashes, even though there are no blobs in the payload.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(), # Send new payload so the parent is unknown to the secondary client
        NewPayloads(
          expectedblobs: @[],
        ),
        LaunchClients(
          #engineStarter:            hive_rpc.HiveRPCEngineStarter{),
          skipAddingToCLMock:       true,
          skipConnectingToBootnode: true, # So the client is in a perpetual syncing state
        ),
        SendModifiedLatestPayload(
          clientID: 1,
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              versionedHashesCustomizer: VersionedHashesCustomizer(
                blobs: Opt.some(@[BlobID(0)]),
              ),
            ),
            expectInvalidStatus: true,
          ),
        ),
      ]
    ),
  ),

  # BlobGasUsed, ExcessBlobGas Negative Tests
  # Most cases are contained in https:#github.com/ethereum/execution-spec-tests/tree/main/tests/cancun/eip4844_blobs
  # and can be executed using """pyspec""" simulator.
  TestDesc(
    name: "Incorrect blobGasUsed: Non-Zero on Zero Blobs",
    about: """
      Send a payload with zero blobs, but non-zero BlobGasUsed.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              blobGasUsed: Opt.some(1'u64),
            ),
            expectInvalidStatus: true,
          ),
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "Incorrect blobGasUsed: GAS_PER_BLOB on Zero Blobs",
    about: """
      Send a payload with zero blobs, but non-zero BlobGasUsed.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              blobGasUsed: Opt.some(GAS_PER_BLOB.uint64),
            ),
            expectInvalidStatus: true,
          ),
        ).TestStep,
      ]
    ),
  ),

  # DevP2P tests
  TestDesc(
    name: "Request Blob Pooled Transactions",
    about: """
      Requests blob pooled transactions and verify correct encoding.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
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
        DevP2PRequestPooledTransactionHash(
          clientIndex:                 0,
          transactionIndexes:          @[0],
          waitForNewPooledTransaction: true,
        ),
      ]
    ),
  ),

  # Need special rlp encoder
  #[TestDescXXX(
    name: "NewPayloadV3 Before Cancun, 0x00 ExcessBlobGas, Nil BlobGasUsed, Nil Versioned Hashes, Nil Beacon Root",
    about: """
      Test sending NewPayloadV3 Before Cancun with:
      - 0x00 ExcessBlobGas
      - nil BlobGasUsed
      - nil Versioned Hashes Array
      - nil Beacon Root
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: UpgradeNewPayloadVersion(
            payloadCustomizer: CustomPayloadData(
              excessBlobGas: some(0'u64),
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  TestDescXXX(
    name: "NewPayloadV3 Before Cancun, Nil Data Fields, Nil Versioned Hashes, Zero Beacon Root",
    about: """
      Test sending NewPayloadV3 Before Cancun with:
      - nil ExcessBlobGas
      - nil BlobGasUsed
      - nil Versioned Hashes Array
      - Zero Beacon Root
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 2,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: UpgradeNewPayloadVersion(
            payloadCustomizer: CustomPayloadData(
              parentBeaconRoot: some(common.Hash256()),
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 before Cancun with any nil field must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  # NewPayloadV3 After Cancun, Negative Tests
  TestDescXXX(
    name: "NewPayloadV3 After Cancun, Nil ExcessBlobGas, 0x00 BlobGasUsed, Empty Array Versioned Hashes, Zero Beacon Root",
    about: """
      Test sending NewPayloadV3 After Cancun with:
      - nil ExcessBlobGas
      - 0x00 BlobGasUsed
      - Empty Versioned Hashes Array
      - Zero Beacon Root
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 1,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              removeExcessBlobGas: true,
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 after Cancun with nil ExcessBlobGas must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  TestDescXXX(
    name: "NewPayloadV3 After Cancun, 0x00 ExcessBlobGas, Nil BlobGasUsed, Empty Array Versioned Hashes",
    about: """
      Test sending NewPayloadV3 After Cancun with:
      - 0x00 ExcessBlobGas
      - nil BlobGasUsed
      - Empty Versioned Hashes Array
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      forkHeight: 1,
      testSequence: @[
        NewPayloads(
          newPayloadCustomizer: BaseNewPayloadVersionCustomizer(
            payloadCustomizer: CustomPayloadData(
              removeblobGasUsed: true,
            ),
            expectedError: engineApiInvalidParams,
          ),
          expectationDescription: """
          NewPayloadV3 after Cancun with nil BlobGasUsed must return INVALID_PARAMS_ERROR (code $1)
          """ % [$engineApiInvalidParams],
        ).TestStep,
      ]
    ),
  ),

  TestDesc(
    name: "Parallel Blob Transactions",
    about: """
      Test sending multiple blob transactions in parallel from different accounts.

      Verify that a payload is created with the maximum number of blobs.
      """,
    run: specExecute,
    spec: CancunSpec(
      mainFork: ForkCancun,
      testSequence: @[
        # Send multiple blob transactions with the same nonce.
        ParallelSteps{
          Steps: []TestStep{
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  0,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  1,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  2,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  3,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  4,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  5,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  6,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  7,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  8,
            ),
            SendBlobTransactions(
              transactionCount:              5,
              blobsPerTransaction:           MAX_BLOBS_PER_BLOCK,
              blobTransactionMaxBlobGasCost: u256(100),
              accountIndex:                  9,
            ),
          ),
        ),

        # We create the first payload, which is guaranteed to have the first MAX_BLOBS_PER_BLOCK blobs.
        NewPayloads(
          expectedIncludedBlobCount: MAX_BLOBS_PER_BLOCK,
          expectedblobs:             getBlobList(0, MAX_BLOBS_PER_BLOCK),
        ),
      ]
    ),
  ),]#
]

proc makeCancunTest(): seq[EngineSpec] =
  # Append all engine api tests with Cancun as main fork
  #[for x in engineTestList:
    let t = EngineSpec(x.spec)
    result.add t.withMainFork(ForkCancun).EngineSpec]#

  # Payload Attributes
  for syncing in [false, true]:
    result.add InvalidPayloadAttributesTest(
      description: "Missing BeaconRoot",
      mainFork   : ForkCancun,
      syncing    : syncing,
      customizer : BasePayloadAttributesCustomizer(
        removeBeaconRoot: true,
      )
    )

  const
    payloadIdTests = [
      PayloadAttributesParentBeaconRoot,
      # TODO: Remove when withdrawals suite is refactored
      PayloadAttributesAddWithdrawal,
      PayloadAttributesModifyWithdrawalAmount,
      PayloadAttributesModifyWithdrawalIndex,
      PayloadAttributesModifyWithdrawalValidator,
      PayloadAttributesModifyWithdrawalAddress,
      PayloadAttributesRemoveWithdrawal,
    ]

  # Unique Payload ID Tests
  for t in payloadIdTests:
    result.add UniquePayloadIDTest(
      mainFork: ForkCancun,
      fieldModification: t,
    )

  # Invalid Payload Tests
  const
    invalidFields = [
      InvalidParentBeaconBlockRoot,
      InvalidBlobGasUsed,
      InvalidBlobCountGasUsed,
      InvalidExcessBlobGas,
      InvalidVersionedHashes,
      InvalidVersionedHashesVersion,
      IncompleteVersionedHashes,
      ExtraVersionedHashes,
    ]

    invalidDetectedOnSyncs = [
      InvalidBlobGasUsed,
      InvalidBlobCountGasUsed,
      InvalidVersionedHashes,
      InvalidVersionedHashesVersion,
      IncompleteVersionedHashes,
      ExtraVersionedHashes
    ]

    nilLatestValidHashes = [
      InvalidVersionedHashes,
      InvalidVersionedHashesVersion,
      IncompleteVersionedHashes,
      ExtraVersionedHashes
    ]

  for invalidField in invalidFields:
    for syncing in [false, true]:
      # Invalidity of payload can be detected even when syncing because the
      # blob gas only depends on the transactions contained.
      let
        invalidDetectedOnSync = invalidField in invalidDetectedOnSyncs
        nilLatestValidHash = invalidField in nilLatestValidHashes

      result.add InvalidPayloadTestCase(
        mainFork             : ForkCancun,
        txType               : Opt.some(TxEIP4844),
        invalidField         : invalidField,
        syncing              : syncing,
        invalidDetectedOnSync: invalidDetectedOnSync,
        nilLatestValidHash   : nilLatestValidHash,
      )

  # Invalid Transaction ChainID Tests
  result.add InvalidTxChainIDTest(
    mainFork: ForkCancun,
    txType  : Opt.some(TxEIP4844),
  )

  result.add PayloadBuildAfterInvalidPayloadTest(
    mainFork: ForkCancun,
    txType  : Opt.some(TxEIP4844),
    invalidField: InvalidParentBeaconBlockRoot,
  )

  # Suggested Fee Recipient Tests (New Transaction Type)
  result.add SuggestedFeeRecipientTest(
    mainFork: ForkCancun,
    txType  : Opt.some(TxEIP4844),
    transactionCount: 1, # Only one blob tx gets through due to blob gas limit
  )

  # Prev Randao Tests (New Transaction Type)
  result.add PrevRandaoTransactionTest(
    mainFork: ForkCancun,
    txType  : Opt.some(TxEIP4844),
  )

proc getGenesisProc(cs: BaseSpec, param: NetworkParams) =
  getGenesis(param)

proc filCancunTests(): seq[TestDesc] =
  result.add cancunTestListA

  let list = makeCancunTest()
  for x in list:
    var z = x
    z.getGenesisFn = getGenesisProc
    result.add TestDesc(
      name: x.getName(),
      run: executeEngineSpec,
      spec: z,
    )

let cancunTestList* = filCancunTests()

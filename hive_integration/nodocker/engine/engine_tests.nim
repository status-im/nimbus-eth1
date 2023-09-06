import
  ./engine/engine_spec,
  ./types,
  ./test_env

proc specExecute(ws: BaseSpec): bool =
  var
    ws = EngineSpec(ws)
    env = TestEnv.new(ws.chainFile, false)

  env.engine.setRealTTD(ws.ttd)
  env.setupCLMock()
  
  if ws.slotsToFinalized != 0:
    env.slotsToFinalized(ws.slotsToFinalized)
  if ws.slotsToSafe != 0:
    env.slotsToSafe(ws.slotsToSafe)

  result = ws.exec(env)
  env.close()

let engineTestList* = [
  # Engine API Negative Test Cases
  TestDesc(
    name: "Invalid Terminal Block in ForkchoiceUpdated",
    run: specExecute,
    spec: EngineSpec(
      exec: invalidTerminalBlockForkchoiceUpdated,
      ttd: 1000000
  ))#[,
  TestDesc(
    name: "Invalid GetPayload Under PoW",
    run: specExecute,
    spec: EngineSpec(
      exec: invalidGetPayloadUnderPoW,
      ttd: 1000000
  )),
  TestDesc(
    name: "Invalid Terminal Block in NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidTerminalBlockNewPayload,
      ttd:  1000000,
  )),
  TestDesc(
    name: "Inconsistent Head in ForkchoiceState",
    run: specExecute,
    spec: EngineSpec(
      exec:  inconsistentForkchoiceState1,
  )),
  TestDesc(
    name: "Inconsistent Safe in ForkchoiceState",
    run: specExecute,
    spec: EngineSpec(
      exec:  inconsistentForkchoiceState2,
  )),
  TestDesc(
    name: "Inconsistent Finalized in ForkchoiceState",
    run: specExecute,
    spec: EngineSpec(
      exec:  inconsistentForkchoiceState3,
  )),
  TestDesc(
    name: "Unknown HeadBlockHash",
    run: specExecute,
    spec: EngineSpec(
      exec:  unknownHeadBlockHash,
  )),
  TestDesc(
    name: "Unknown SafeBlockHash",
    run: specExecute,
    spec: EngineSpec(
      exec:  unknownSafeBlockHash,
  )),
  TestDesc(
    name: "Unknown FinalizedBlockHash",
    run: specExecute,
    spec: EngineSpec(
      exec:  unknownFinalizedBlockHash,
  )),
  TestDesc(
    name: "ForkchoiceUpdated Invalid Payload Attributes",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayloadAttributes1,
  )),
  TestDesc(
    name: "ForkchoiceUpdated Invalid Payload Attributes (Syncing)",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayloadAttributes2,
  )),
  TestDesc(
    name: "Pre-TTD ForkchoiceUpdated After PoS Switch",
    run: specExecute,
    spec: EngineSpec(
      exec:  preTTDFinalizedBlockHash,
      ttd:  2,
  )),
  # Invalid Payload Tests
  TestDesc(
    name: "Bad Hash on NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  badHashOnNewPayload1,
  )),
  TestDesc(
    name: "Bad Hash on NewPayload Syncing",
    run: specExecute,
    spec: EngineSpec(
      exec:  badHashOnNewPayload2,
  )),
  TestDesc(
    name: "Bad Hash on NewPayload Side Chain",
    run: specExecute,
    spec: EngineSpec(
      exec:  badHashOnNewPayload3,
  )),
  TestDesc(
    name: "Bad Hash on NewPayload Side Chain Syncing",
    run: specExecute,
    spec: EngineSpec(
      exec:  badHashOnNewPayload4,
  )),
  TestDesc(
    name: "ParentHash==BlockHash on NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  parentHashOnExecPayload,
  )),
  TestDesc(
    name: "Invalid Transition Payload",
    run: specExecute,
    spec: EngineSpec(
      exec: invalidTransitionPayload,
      ttd: 393504,
      chainFile: "blocks_2_td_393504.rlp",
  )),
  TestDesc(
    name: "Invalid ParentHash NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload1,
  )),
  TestDesc(
    name: "Invalid StateRoot NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload2,
  )),
  TestDesc(
    name: "Invalid StateRoot NewPayload, Empty Transactions",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload3,
  )),
  TestDesc(
    name: "Invalid ReceiptsRoot NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload4,
  )),
  TestDesc(
    name: "Invalid Number NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload5,
  )),
  TestDesc(
    name: "Invalid GasLimit NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload6,
  )),
  TestDesc(
    name: "Invalid GasUsed NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload7,
  )),
  TestDesc(
    name: "Invalid Timestamp NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload8,
  )),
  TestDesc(
    name: "Invalid PrevRandao NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload9,
  )),
  TestDesc(
    name: "Invalid Incomplete Transactions NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload10,
  )),
  TestDesc(
    name: "Invalid Transaction Signature NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload11,
  )),
  TestDesc(
    name: "Invalid Transaction Nonce NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload12,
  )),
  TestDesc(
    name: "Invalid Transaction GasPrice NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload13,
  )),
  TestDesc(
    name: "Invalid Transaction Gas NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload14,
  )),
  TestDesc(
    name: "Invalid Transaction Value NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidPayload15,
  )),

  # Invalid Ancestor Re-Org Tests (Reveal via newPayload)
  TestDesc(
    name: "Invalid Ancestor Chain Re-Org, Invalid StateRoot, Invalid P1', Reveal using newPayload",
    slotsToFinalized: 20,
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidMissingAncestor1,
  )),
  TestDesc(
    name: "Invalid Ancestor Chain Re-Org, Invalid StateRoot, Invalid P9', Reveal using newPayload",
    slotsToFinalized: 20,
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidMissingAncestor2,
  )),
  TestDesc(
    name: "Invalid Ancestor Chain Re-Org, Invalid StateRoot, Invalid P10', Reveal using newPayload",
    slotsToFinalized: 20,
    run: specExecute,
    spec: EngineSpec(
      exec:  invalidMissingAncestor3,
  )),

  # Eth RPC Status on ForkchoiceUpdated Events
  TestDesc(
    name: "Latest Block after NewPayload",
    run: specExecute,
    spec: EngineSpec(
      exec:  blockStatusExecPayload1,
  )),
  TestDesc(
    name: "Latest Block after NewPayload (Transition Block)",
    run: specExecute,
    spec: EngineSpec(
      exec:  blockStatusExecPayload2,
      ttd:  5,
  )),
  TestDesc(
    name: "Latest Block after New HeadBlock",
    run: specExecute,
    spec: EngineSpec(
      exec:  blockStatusHeadBlock1,
  )),
  TestDesc(
    name: "Latest Block after New HeadBlock (Transition Block)",
    run: specExecute,
    spec: EngineSpec(
      exec:  blockStatusHeadBlock2,
      ttd:  5,
  )),
  TestDesc(
    name: "safe Block after New SafeBlockHash",
    run: specExecute,
    spec: EngineSpec(
      exec:  blockStatusSafeBlock,
      ttd:  5,
  )),
  TestDesc(
    name: "finalized Block after New FinalizedBlockHash",
    run: specExecute,
    spec: EngineSpec(
      exec:  blockStatusFinalizedBlock,
      ttd:  5,
  )),
  TestDesc(
    name: "Latest Block after Reorg",
    run: specExecute,
    spec: EngineSpec(
      exec:  blockStatusReorg,
  )),

  # Payload Tests
  TestDesc(
    name: "Re-Execute Payload",
    run: specExecute,
    spec: EngineSpec(
      exec:  reExecPayloads,
  )),
  TestDesc(
    name: "Multiple New Payloads Extending Canonical Chain",
    run: specExecute,
    spec: EngineSpec(
      exec:  multipleNewCanonicalPayloads,
  )),
  TestDesc(
    name: "Out of Order Payload Execution",
    run: specExecute,
    spec: EngineSpec(
      exec:  outOfOrderPayloads,
  )),

  # Transaction Reorg using Engine API
  TestDesc(
    name: "Transaction Reorg",
    run: specExecute,
    spec: EngineSpec(
      exec:  transactionReorg,
  )),
  TestDesc(
    name: "Sidechain Reorg",
    run: specExecute,
    spec: EngineSpec(
      exec:  sidechainReorg,
  )),
  TestDesc(
    name: "Re-Org Back into Canonical Chain",
    run: specExecute,
    spec: EngineSpec(
      exec:  reorgBack,
  )),
  TestDesc(
    name: "Re-Org Back to Canonical Chain From Syncing Chain",
    run: specExecute,
    spec: EngineSpec(
      exec:  reorgBackFromSyncing,
  )),

  # Suggested Fee Recipient in Payload creation
  TestDesc(
    name: "Suggested Fee Recipient Test",
    run: specExecute,
    spec: EngineSpec(
      exec:  suggestedFeeRecipient,
  )),

  # PrevRandao opcode tests
  TestDesc(
    name: "PrevRandao Opcode Transactions",
    run: specExecute,
    spec: EngineSpec(
      exec:  prevRandaoOpcodeTx,
      ttd:  10,
  )),

  # Multi-Client Sync tests
  TestDesc(
    name: "Sync Client Post Merge",
    run: specExecute,
    spec: EngineSpec(
      exec:  postMergeSync,
      ttd:  10,
  )),]#
]

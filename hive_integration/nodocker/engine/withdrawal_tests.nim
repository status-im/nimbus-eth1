import
  withdrawals/wd_base_spec,
  withdrawals/wd_block_value_spec,
  withdrawals/wd_max_init_code_spec,
  #withdrawals/wd_payload_body_spec,
  withdrawals/wd_reorg_spec,
  withdrawals/wd_sync_spec,
  ./types,
  ./test_env,
  ./base_spec

proc specExecute[T](ws: BaseSpec): bool =
  ws.mainFork = ForkShanghai
  let
    ws   = T(ws)
    conf = envConfig(ws.getForkConfig())

  discard ws.getGenesis(conf.networkParams)

  let env  = TestEnv.new(conf)
  env.engine.setRealTTD(0)
  env.setupCLMock()
  ws.configureCLMock(env.clMock)
  result = ws.execute(env)
  env.close()

let wdTestList* = [
  #Re-Org tests
  TestDesc(
    name: "Withdrawals Fork on Block 1 - 8 Block Re-Org, Sync",
    about: "Tests a 8 block re-org using NewPayload. Re-org does not change withdrawals fork height",
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 1, # Genesis is Pre-Withdrawals
      wdBlockCount: MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      reOrgBlockCount: 8,
      reOrgViaSync:    true,
  )),
  TestDesc(
    name: "Withdrawals Fork on Block 8 - 10 Block Re-Org Sync",
    about: " Tests a 10 block re-org using sync",
      # Re-org does not change withdrawals fork height, but changes
      #  the payload at the height of the fork
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 8, # Genesis is Pre-Withdrawals
      wdBlockCount: 8,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      reOrgBlockCount: 10,
      reOrgViaSync:    true,
  )),
  TestDesc(
    name: "Withdrawals Fork on Canonical Block 8 / Side Block 7 - 10 Block Re-Org Sync",
    about: "Tests a 10 block re-org using sync",
      # Sidechain reaches withdrawals fork at a lower block height
      # than the canonical chain
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 8, # Genesis is Pre-Withdrawals
      wdBlockCount: 8,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      reOrgBlockCount:         10,
      reOrgViaSync:            true,
      sidechaintimeIncrements: 2,
  )),
  TestDesc(
    name: "Withdrawals Fork on Canonical Block 8 / Side Block 9 - 10 Block Re-Org Sync",
    about: "Tests a 10 block re-org using sync",
      # Sidechain reaches withdrawals fork at a higher block height
      # than the canonical chain
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 8, # Genesis is Pre-Withdrawals
      wdBlockCount: 8,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      blockTimestampIncrement: 2,
      reOrgBlockCount:         10,
      reOrgViaSync:            true,
      sidechaintimeIncrements: 1,
  )),
  TestDesc(
    name: "Withdrawals Fork on Block 1 - 1 Block Re-Org",
    about: "Tests a simple 1 block re-org",
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 1, # Genesis is Pre-Withdrawals
      wdBlockCount: MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      reOrgBlockCount: 1,
      reOrgViaSync:    false,
  )),
  TestDesc(
    name: "Withdrawals Fork on Block 1 - 8 Block Re-Org NewPayload",
    about: "Tests a 8 block re-org using NewPayload. Re-org does not change withdrawals fork height",
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 1, # Genesis is Pre-Withdrawals
      wdBlockCount: MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      reOrgBlockCount: 8,
      reOrgViaSync:    false,
  )),
  TestDesc(
    name: "Withdrawals Fork on Block 8 - 10 Block Re-Org NewPayload",
    about: "Tests a 10 block re-org using NewPayload\n" &
        "Re-org does not change withdrawals fork height, but changes\n" &
        "the payload at the height of the fork\n",
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 8, # Genesis is Pre-Withdrawals
      wdBlockCount: 8,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      reOrgBlockCount: 10,
      reOrgViaSync:    false,
  )),
  TestDesc(
    name: "Withdrawals Fork on Canonical Block 8 / Side Block 7 - 10 Block Re-Org",
    about: "Tests a 10 block re-org using NewPayload",
      # Sidechain reaches withdrawals fork at a lower block height
      # than the canonical chain
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 8, # Genesis is Pre-Withdrawals
      wdBlockCount: 8,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      reOrgBlockCount:         10,
      reOrgViaSync:            false,
      sidechaintimeIncrements: 2,
  )),
  TestDesc(
    name: "Withdrawals Fork on Canonical Block 8 / Side Block 9 - 10 Block Re-Org",
    about: "Tests a 10 block re-org using NewPayload",
      # Sidechain reaches withdrawals fork at a higher block height
      # than the canonical chain
    run: specExecute[ReorgSpec],
    spec: ReorgSpec(
      slotsToSafe:      32,
      slotsToFinalized: 64,
      timeoutSeconds:   300,
      forkHeight: 8, # Genesis is Pre-Withdrawals
      wdBlockCount: 8,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      blockTimestampIncrement: 2,
      reOrgBlockCount:         10,
      reOrgViaSync:            false,
      sidechaintimeIncrements: 1,
  )),

  # Sync Tests
  TestDesc(
    name: "Sync after 2 blocks - Withdrawals on Block 1 - Single Withdrawal Account - No Transactions",
    about: "- Spawn a first client\n" &
      "- Go through withdrawals fork on Block 1\n" &
      "- Withdraw to a single account MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK times each block for 2 blocks\n" &
      "- Spawn a secondary client and send FCUV2(head)\n" &
      "- Wait for sync and verify withdrawn account's balance\n",
    run: specExecute[SyncSpec],
    spec: SyncSpec(
      timeoutSeconds:  6,
      forkHeight:    1,
      wdBlockCount:    2,
      wdPerBlock:      MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: 1,
      txPerBlock:     some(0),
      syncSteps: 1,
  )),
  TestDesc(
    name: "Sync after 2 blocks - Withdrawals on Block 1 - Single Withdrawal Account",
    about: "- Spawn a first client\n" &
      "- Go through withdrawals fork on Block 1\n" &
      "- Withdraw to a single account MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK times each block for 2 blocks\n" &
      "- Spawn a secondary client and send FCUV2(head)\n" &
      "- Wait for sync and verify withdrawn account's balance\n",
    run: specExecute[SyncSpec],
    spec: SyncSpec(
      forkHeight:    1,
      wdBlockCount:    2,
      wdPerBlock:      MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: 1,
      syncSteps: 1,
  )),
  TestDesc(
    name: "Sync after 2 blocks - Withdrawals on Genesis - Single Withdrawal Account",
    about: "- Spawn a first client, with Withdrawals since genesis\n" &
      "- Withdraw to a single account MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK times each block for 2 blocks\n" &
      "- Spawn a secondary client and send FCUV2(head)\n" &
      "- Wait for sync and verify withdrawn account's balance\n",
    run: specExecute[SyncSpec],
    spec: SyncSpec(
      forkHeight:    0,
      wdBlockCount:    2,
      wdPerBlock:      MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: 1,
      syncSteps: 1,
  )),
  TestDesc(
    name: "Sync after 2 blocks - Withdrawals on Block 2 - Multiple Withdrawal Accounts - No Transactions",
    about: "- Spawn a first client\n" &
      "- Go through withdrawals fork on Block 2\n" &
      "- Withdraw to MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK accounts each block for 2 blocks\n" &
      "- Spawn a secondary client and send FCUV2(head)\n" &
      "- Wait for sync, which include syncing a pre-Withdrawals block, and verify withdrawn account's balance\n",
    run: specExecute[SyncSpec],
    spec: SyncSpec(
      forkHeight:    2,
      wdBlockCount:    2,
      wdPerBlock:      MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      txPerBlock:      some(0),
      syncSteps: 1,
  )),
  TestDesc(
    name: "Sync after 2 blocks - Withdrawals on Block 2 - Multiple Withdrawal Accounts",
    about: "- Spawn a first client\n" &
      "- Go through withdrawals fork on Block 2\n" &
      "- Withdraw to MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK accounts each block for 2 blocks\n" &
      "- Spawn a secondary client and send FCUV2(head)\n" &
      "- Wait for sync, which include syncing a pre-Withdrawals block, and verify withdrawn account's balance\n",
    run: specExecute[SyncSpec],
    spec: SyncSpec(
      forkHeight:    2,
      wdBlockCount:    2,
      wdPerBlock:      MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      syncSteps: 1,
  )),
  TestDesc(
    name: "Sync after 128 blocks - Withdrawals on Block 2 - Multiple Withdrawal Accounts",
    about: "- Spawn a first client\n" &
      "- Go through withdrawals fork on Block 2\n" &
      "- Withdraw to many accounts MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK times each block for 128 blocks\n" &
      "- Spawn a secondary client and send FCUV2(head)\n" &
      "- Wait for sync, which include syncing a pre-Withdrawals block, and verify withdrawn account's balance\n",
    run: specExecute[SyncSpec],
    spec: SyncSpec(
      timeoutSeconds:  100,
      forkHeight:    2,
      wdBlockCount:    128,
      wdPerBlock:      MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: 1024,
      syncSteps: 1,
  )),

  # EVM Tests (EIP-3651, EIP-3855, EIP-3860)
  TestDesc(
    name: "Max Initcode Size",
    run: specExecute[MaxInitcodeSizeSpec],
    spec: MaxInitcodeSizeSpec(
      forkHeight: 2, # Block 1 is Pre-Withdrawals
      wdBlockCount: 2,
      overflowMaxInitcodeTxCountBeforeFork: 0,
      overflowMaxInitcodeTxCountAfterFork:  1,
  )),
  # Block value tests
  TestDesc(
    name: "GetPayloadV2 Block Value",
    about: "Verify the block value returned in GetPayloadV2.",
    run: specExecute[BlockValueSpec],
    spec: BlockValueSpec(
      forkHeight: 1,
      wdBlockCount: 1,
  )),
  # Base tests
  TestDesc(
    name: "Withdrawals Fork On Genesis",
    about: "Tests the withdrawals fork happening since genesis (e.g. on a testnet).",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight: 0,
      wdBlockCount: 2, # Genesis is a withdrawals block
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
  )),
  TestDesc(
    name: "Withdrawals Fork on Block 1",
    about: "Tests the withdrawals fork happening directly after genesis.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight: 1, # Only Genesis is Pre-Withdrawals
      wdBlockCount: 1,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
  )),
  TestDesc(
    name: "Withdrawals Fork on Block 2",
    about: "Tests the transition to the withdrawals fork after a single block" &
      " has happened.  Block 1 is sent with invalid non-null withdrawals payload and" &
      " client is expected to respond with the appropriate error.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight: 2, # Genesis and Block 1 are Pre-Withdrawals
      wdBlockCount: 1,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
  )),
  TestDesc(
    name: "Withdrawals Fork on Block 3",
    about: "Tests the transition to the withdrawals fork after two blocks" &
      " have happened. Block 2 is sent with invalid non-null withdrawals payload and" &
      " client is expected to respond with the appropriate error.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight: 3, # Genesis, Block 1 and 2 are Pre-Withdrawals
      wdBlockCount: 1,
      wdPerBlock:   MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
  )),
  TestDesc(
    name: "Withdraw to a single account",
    about: "Make multiple withdrawals to a single account.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight:    1,
      wdBlockCount:    1,
      wdPerBlock:    MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: 1,
  )),
  TestDesc(
    name: "Withdraw to two accounts",
    about: "Make multiple withdrawals to two different accounts, repeated in" &
      " round-robin. Reasoning: There might be a difference in implementation when an" &
      " account appears multiple times in the withdrawals list but the list" &
      " is not in ordered sequence.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight:    1,
      wdBlockCount:    1,
      wdPerBlock:    MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: 2,
  )),
  TestDesc(
    name: "Withdraw many accounts",
    about: "Make multiple withdrawals to MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK * 5 different accounts." &
      " Execute many blocks this way.",
    # TimeoutSeconds: 240,
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight:    1,
      wdBlockCount:    4,
      wdPerBlock:    MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK * 5,
      wdAbleAccountCount: 1024,
  )),
  TestDesc(
    name: "Withdraw zero amount",
    about: "Make multiple withdrawals where the amount withdrawn is 0.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight:    1,
      wdBlockCount:    1,
      wdPerBlock:    MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK,
      wdAbleAccountCount: 2,
      wdAmounts: @[0'u64, 1'u64]
  )),
  TestDesc(
    name: "Empty Withdrawals",
    about: "Produce withdrawals block with zero withdrawals.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight: 1,
      wdBlockCount: 1,
      wdPerBlock:   0,
  )),
  TestDesc(
    name: "Corrupted Block Hash Payload (INVALID)",
    about: "Send a valid payload with a corrupted hash using engine_newPayloadV2.",
    run: specExecute[WDBaseSpec],
    spec: WDBaseSpec(
      forkHeight:    1,
      wdBlockCount:    1,
      testCorrupedHashPayloads: true,
    )
  ),
]

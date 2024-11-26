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
  stint,
  chronicles,
  chronos,
  web3/eth_api_types,
  ./wd_history,
  ../test_env,
  ../engine_client,
  ../types,
  ../base_spec,
  ../cancun/customizer,
  ../../../../nimbus/common/common,
  ../../../../nimbus/utils/utils,
  ../../../../nimbus/common/chain_config,
  web3/execution_types,
  ../../../../nimbus/beacon/web3_eth_conv

type
  WDBaseSpec* = ref object of BaseSpec
    wdBlockCount*:       int          # Number of blocks on and after withdrawals fork activation
    wdPerBlock*:         int          # Number of withdrawals per block
    wdAbleAccountCount*: int          # Number of accounts to withdraw to (round-robin)
    wdHistory*:          WDHistory    # Internal withdrawals history that keeps track of all withdrawals
    wdAmounts*:          seq[uint64]  # Amounts of withdrawn wei on each withdrawal (round-robin)
    txPerBlock*:         Opt[int]  # Amount of test transactions to include in withdrawal blocks
    testCorrupedHashPayloads*: bool   # Send a valid payload with corrupted hash
    skipBaseVerifications*:    bool   # For code reuse of the base spec procedure

  WithdrawalsForBlock = object
    wds*: seq[Withdrawal]
    nextIndex*: int

const
  WARM_COINBASE_ADDRESS = address"0x0101010101010101010101010101010101010101"
  PUSH0_ADDRESS         = address"0x0202020202020202020202020202020202020202"
  MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK* = 16
  TX_CONTRACT_ADDRESSES = [
    WARM_COINBASE_ADDRESS,
    PUSH0_ADDRESS,
  ]

# Timestamp delta between genesis and the withdrawals fork
func getWithdrawalsGenesisTimeDelta*(ws: WDBaseSpec): int =
  ws.forkHeight * ws.getBlockTimeIncrements()

# Get the start account for all withdrawals.
func getWithdrawalsStartAccount*(ws: WDBaseSpec): UInt256 =
  0x1000.u256

# Adds bytecode that unconditionally sets an storage key to specified account range
func addUnconditionalBytecode(g: Genesis, start, stop: UInt256) =
  var acc = start
  while acc<stop:
    let accountAddress = toAddress(acc)
    # Bytecode to unconditionally set a storage key
    g.alloc[accountAddress] = GenesisAccount(
      code: @[
        0x60.byte, # PUSH1(0x01)
        0x01.byte,
        0x60.byte, # PUSH1(0x00)
        0x00.byte,
        0x55.byte, # SSTORE
        0x00.byte, # STOP
      ], # sstore(0, 1)
      nonce:   0.AccountNonce,
      balance: 0.u256,
    )
    acc = acc + 1

func getWithdrawableAccountCount*(ws: WDBaseSpec):int =
  if ws.wdAbleAccountCount == 0:
    # Withdraw to MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK accounts by default
    return MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK
  return ws.wdAbleAccountCount

# Append the accounts we are going to withdraw to, which should also include
# bytecode for testing purposes.
func getGenesis*(ws: WDBaseSpec, param: NetworkParams) =
  # Remove PoW altogether
  param.genesis.difficulty = 0.u256
  param.config.terminalTotalDifficulty = Opt.some(0.u256)
  param.genesis.extraData = @[]

  # Add some accounts to withdraw to with unconditional SSTOREs
  let
    startAccount = 0x1000.u256
    endAccount = (0x1000 + ws.getWithdrawableAccountCount()).u256
  addUnconditionalBytecode(param.genesis, startAccount, endAccount)

  # Add accounts that use the coinbase (EIP-3651)
  let warmCoinbaseCode = [
    0x5A.byte, # GAS
    0x60.byte, # PUSH1(0x00)
    0x00.byte,
    0x60.byte, # PUSH1(0x00)
    0x00.byte,
    0x60.byte, # PUSH1(0x00)
    0x00.byte,
    0x60.byte, # PUSH1(0x00)
    0x00.byte,
    0x60.byte, # PUSH1(0x00)
    0x00.byte,
    0x41.byte, # COINBASE
    0x60.byte, # PUSH1(0xFF)
    0xFF.byte,
    0xF1.byte, # CALL
    0x5A.byte, # GAS
    0x90.byte, # SWAP1
    0x50.byte, # POP - Call result
    0x90.byte, # SWAP1
    0x03.byte, # SUB
    0x60.byte, # PUSH1(0x16) - GAS + PUSH * 6 + COINBASE
    0x16.byte,
    0x90.byte, # SWAP1
    0x03.byte, # SUB
    0x43.byte, # NUMBER
    0x55.byte, # SSTORE
  ]

  param.genesis.alloc[WARM_COINBASE_ADDRESS] = GenesisAccount(
    code:    @warmCoinbaseCode,
    balance: 0.u256,
  )

  # Add accounts that use the PUSH0 (EIP-3855)
  let push0Code = [
    0x43.byte, # NUMBER
    0x5F.byte, # PUSH0
    0x55.byte, # SSTORE
  ]

  param.genesis.alloc[PUSH0_ADDRESS] = GenesisAccount(
    code:    @push0Code,
    balance: 0.u256,
  )

func getTransactionCountPerPayload*(ws: WDBaseSpec): int =
  ws.txPerBlock.get(16)

proc verifyContractsStorage(ws: WDBaseSpec, env: TestEnv): Result[void, string] =
  if ws.getTransactionCountPerPayload() < TX_CONTRACT_ADDRESSES.len:
    return

  # Assume that forkchoice updated has been already sent
  let
    latestPayloadNumber = env.clMock.latestExecutedPayload.blockNumber.uint64
    r = env.client.storageAt(WARM_COINBASE_ADDRESS, latestPayloadNumber.u256, latestPayloadNumber)
    p = env.client.storageAt(PUSH0_ADDRESS, 0.u256, latestPayloadNumber)

  if latestPayloadNumber >= ws.forkHeight.uint64:
    # Shanghai
    r.expectStorageEqual(WARM_COINBASE_ADDRESS, 100.u256.to(Bytes32))    # WARM_STORAGE_READ_COST
    p.expectStorageEqual(PUSH0_ADDRESS, latestPayloadNumber.u256.to(Bytes32)) # tx succeeded
  else:
    # Pre-Shanghai
    r.expectStorageEqual(WARM_COINBASE_ADDRESS, 2600.u256.to(Bytes32)) # COLD_ACCOUNT_ACCESS_COST
    p.expectStorageEqual(PUSH0_ADDRESS, 0.u256.to(Bytes32))            # tx must've failed

  ok()

# Number of blocks to be produced (not counting genesis) before withdrawals
# fork.
func getPreWithdrawalsBlockCount*(ws: WDBaseSpec): int =
  if ws.forkHeight == 0:
    0
  else:
    ws.forkHeight - 1

# Number of payloads to be produced (pre and post withdrawals) during the entire test
func getTotalPayloadCount*(ws: WDBaseSpec): int =
  ws.getPreWithdrawalsBlockCount() + ws.wdBlockCount

# Generates a list of withdrawals based on current configuration
func generateWithdrawalsForBlock*(ws: WDBaseSpec, nextIndex: int, startAccount: UInt256): WithdrawalsForBlock =
  let
    differentAccounts = ws.getWithdrawableAccountCount()

  var wdAmounts = ws.wdAmounts
  if wdAmounts.len == 0:
    wdAmounts.add(1)

  for i in 0 ..< ws.wdPerBlock:
    let
      nextAccount = startAccount + (nextIndex mod differentAccounts).u256
      nextWithdrawal = Withdrawal(
        index:          nextIndex.uint64,
        validatorIndex: nextIndex.uint64,
        address:        nextAccount.toAddress,
        amount:         wdAmounts[nextIndex mod wdAmounts.len]
      )

    result.wds.add nextWithdrawal
    inc result.nextIndex

# Base test case execution procedure for withdrawals
proc execute*(ws: WDBaseSpec, env: TestEnv): bool =
  result = true

  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Check if we have pre-Shanghai blocks
  if ws.getForkTime() > GenesisTimestamp:
    # Check `latest` during all pre-shanghai blocks, none should
    # contain `withdrawalsRoot`, including genesis.

    # Genesis should not contain `withdrawalsRoot` either
    let r = env.client.latestHeader()
    r.expectWithdrawalsRoot(Opt.none(common.Hash32))
  else:
    # Genesis is post shanghai, it should contain EmptyWithdrawalsRoot
    let r = env.client.latestHeader()
    r.expectWithdrawalsRoot(Opt.some(EMPTY_ROOT_HASH))

  # Produce any blocks necessary to reach withdrawals fork
  var pbRes = env.clMock.produceBlocks(ws.getPreWithdrawalsBlockCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      # Send some transactions
      let numTx = ws.getTransactionCountPerPayload()
      for i in 0..<numTx:
        let destAddr = TX_CONTRACT_ADDRESSES[i mod TX_CONTRACT_ADDRESSES.len]
        let ok = env.sendNextTx(
          env.clMock.nextBlockProducer,
          BaseTx(
            recipient: Opt.some(destAddr),
            amount:    1.u256,
            txType:    ws.txType,
            gasLimit:  75000.GasInt,
          ))

        testCond ok:
          error "Error trying to send transaction"

      if not ws.skipBaseVerifications:
        # Try to send a ForkchoiceUpdatedV2 with non-null
        # withdrawals before Shanghai
        var r = env.client.forkchoiceUpdatedV2(
          ForkchoiceStateV1(
            headBlockHash: env.clMock.latestHeader.blockHash,
          ),
          Opt.some(PayloadAttributes(
            timestamp:             w3Qty(env.clMock.latestHeader.timestamp, ws.getBlockTimeIncrements()),
            prevRandao:            default(Bytes32),
            suggestedFeeRecipient: default(Address),
            withdrawals:           Opt.some(newSeq[WithdrawalV1]()),
          ))
        )
        let expectationDescription = "Sent pre-shanghai Forkchoice using ForkchoiceUpdatedV2 + Withdrawals, error is expected"
        r.expectErrorCode(engineApiInvalidParams, expectationDescription)

        # Send a valid Pre-Shanghai request using ForkchoiceUpdatedV2
        # (clMock uses V1 by default)
        r = env.client.forkchoiceUpdatedV2(
          ForkchoiceStateV1(
            headBlockHash: env.clMock.latestHeader.blockHash,
          ),
          Opt.some(PayloadAttributes(
            timestamp:             w3Qty(env.clMock.latestHeader.timestamp, ws.getBlockTimeIncrements()),
            prevRandao:            default(Bytes32),
            suggestedFeeRecipient: default(Address),
            withdrawals:           Opt.none(seq[WithdrawalV1]),
          ))
        )
        let expectationDescription2 = "Sent pre-shanghai Forkchoice ForkchoiceUpdatedV2 + null withdrawals, no error is expected"
        r.expectNoError(expectationDescription2)

      return true
    ,
    onGetPayload: proc(): bool =
      if not ws.skipBaseVerifications:
        # Try to get the same payload but use `engine_getPayloadV2`

        let g = env.client.getPayloadV2(env.clMock.nextPayloadID)
        g.expectPayload(env.clMock.latestPayloadBuilt)

        # Send produced payload but try to include non-nil
        # `withdrawals`, it should fail.
        let emptyWithdrawalsList = newSeq[Withdrawal]()
        let customizer = CustomPayloadData(
          withdrawals: Opt.some(emptyWithdrawalsList),
          parentBeaconRoot: env.clMock.latestPayloadAttributes.parentBeaconBlockRoot
        )
        let payloadPlusWithdrawals = customizer.customizePayload(env.clMock.latestExecutableData).basePayload
        var r = env.client.newPayloadV2(payloadPlusWithdrawals.V1V2)
        #r.ExpectationDescription = "Sent pre-shanghai payload using NewPayloadV2+Withdrawals, error is expected"
        r.expectErrorCode(engineApiInvalidParams)

        # Send valid ExecutionPayloadV1 using engine_newPayloadV2
        r = env.client.newPayloadV2(env.clMock.latestPayloadBuilt.V1V2)
        #r.ExpectationDescription = "Sent pre-shanghai payload using NewPayloadV2, no error is expected"
        r.expectStatus(PayloadExecutionStatus.valid)
      return true
    ,
    onNewPayloadBroadcast: proc(): bool =
      if not ws.skipBaseVerifications:
        # We sent a pre-shanghai FCU.
        # Keep expecting `nil` until Shanghai.
        let r = env.client.latestHeader()
        #r.ExpectationDescription = "Requested "latest" block expecting block to contain
        #" withdrawalRoot=nil, because (block %d).timestamp < shanghaiTime
        r.expectWithdrawalsRoot(Opt.none(common.Hash32))
      return true
    ,
    onForkchoiceBroadcast: proc(): bool =
      if not ws.skipBaseVerifications:
        let r = ws.verifyContractsStorage(env)
        testCond r.isOk:
          error "verifyContractsStorage error", msg=r.error
      return true
  ))

  testCond pbRes

  # Produce requested post-shanghai blocks
  # (At least 1 block will be produced after this procedure ends).
  var
    startAccount = ws.getWithdrawalsStartAccount()
    nextIndex    = 0

  pbRes = env.clMock.produceBlocks(ws.wdBlockCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      if not ws.skipBaseVerifications:
        # Try to send a PayloadAttributesV1 with null withdrawals after
        # Shanghai
        let r = env.client.forkchoiceUpdatedV2(
          ForkchoiceStateV1(
            headBlockHash: env.clMock.latestHeader.blockHash,
          ),
          Opt.some(PayloadAttributes(
            timestamp:             w3Qty(env.clMock.latestHeader.timestamp, ws.getBlockTimeIncrements()),
            prevRandao:            default(Bytes32),
            suggestedFeeRecipient: default(Address),
            withdrawals:           Opt.none(seq[WithdrawalV1]),
          ))
        )
        let expectationDescription = "Sent shanghai fcu using PayloadAttributesV1, error is expected"
        r.expectErrorCode(engineApiInvalidParams, expectationDescription)

      # Send some withdrawals
      let wfb = ws.generateWithdrawalsForBlock(nextIndex, startAccount)
      env.clMock.nextWithdrawals = Opt.some(w3Withdrawals wfb.wds)
      ws.wdHistory.put(env.clMock.currentPayloadNumber, wfb.wds)

      # Send some transactions
      let numTx = ws.getTransactionCountPerPayload()
      for i in 0..<numTx:
        let destAddr = TX_CONTRACT_ADDRESSES[i mod TX_CONTRACT_ADDRESSES.len]

        let ok = env.sendNextTx(
          env.clMock.nextBlockProducer,
          BaseTx(
            recipient: Opt.some(destAddr),
            amount:    1.u256,
            txType:    ws.txType,
            gasLimit:  75000.GasInt,
          ))

        testCond ok:
          error "Error trying to send transaction"

      return true
    ,
    onGetPayload: proc(): bool =
      if not ws.skipBaseVerifications:
        # Send invalid `ExecutionPayloadV1` by replacing withdrawals list
        # with null, and client must respond with `InvalidParamsError`.
        # Note that StateRoot is also incorrect but null withdrawals should
        # be checked first instead of responding `INVALID`
        let customizer = CustomPayloadData(
          removeWithdrawals: true,
          parentBeaconRoot: env.clMock.latestPayloadAttributes.parentBeaconBlockRoot
        )
        let nilWithdrawalsPayload = customizer.customizePayload(env.clMock.latestExecutableData).basePayload
        let r = env.client.newPayloadV2(nilWithdrawalsPayload.V1V2)
        #r.ExpectationDescription = "Sent shanghai payload using ExecutionPayloadV1, error is expected"
        r.expectErrorCode(engineApiInvalidParams)

        # Verify the list of withdrawals returned on the payload built
        # completely matches the list provided in the
        # engine_forkchoiceUpdatedV2 method call
        let res = ws.wdHistory.get(env.clMock.currentPayloadNumber)
        doAssert(res.isOk, "withdrawals sent list was not saved")

        let sentList = res.get
        let wdList = env.clMock.latestPayloadBuilt.withdrawals.get
        testCond sentList.len == wdList.len:
          error "Incorrect list of withdrawals on built payload",
            want=sentList.len,
            get=wdList.len

        for i, x in sentList:
          let z = ethWithdrawal wdList[i]
          testCond z == x:
            error "Incorrect withdrawal", index=i
      return true
    ,
    onNewPayloadBroadcast: proc(): bool =
      # Check withdrawal addresses and verify withdrawal balances
      # have not yet been applied
      if not ws.skipBaseVerifications:
        let addrList = ws.wdHistory.getAddressesWithdrawnOnBlock(env.clMock.latestExecutedPayload.blockNumber.uint64)
        for address in addrList:
          # Test balance at `latest`, which should not yet have the
          # withdrawal applied.
          let expectedAccountBalance = ws.wdHistory.getExpectedAccountBalance(
            address,
            env.clMock.latestExecutedPayload.blockNumber.uint64-1)

          let r = env.client.balanceAt(address)
          #r.ExpectationDescription = fmt.Sprintf(`
          #  Requested balance for account %s on "latest" block
          #  after engine_newPayloadV2, expecting balance to be equal
          #  to value on previous block (%d), since the new payload
          #  has not yet been applied.
          #  `,
          #  addr,
          #  env.clMock.LatestExecutedPayload.Number-1,
          #)
          r.expectBalanceEqual(expectedAccountBalance)

        if ws.testCorrupedHashPayloads:
          var payload = env.clMock.latestExecutedPayload

          # Corrupt the hash
          let randomHash = common.Hash32.randomBytes()
          payload.blockHash = randomHash

          # On engine_newPayloadV2 `INVALID_BLOCK_HASH` is deprecated
          # in favor of reusing `INVALID`
          let n = env.client.newPayloadV2(payload.V1V2)
          n.expectStatus(PayloadExecutionStatus.invalid)
      return true
    ,
    onForkchoiceBroadcast: proc(): bool =
      # Check withdrawal addresses and verify withdrawal balances
      # have been applied
      if not ws.skipBaseVerifications:
        let addrList = ws.wdHistory.getAddressesWithdrawnOnBlock(env.clMock.latestExecutedPayload.blockNumber.uint64)
        for address in addrList:
          # Test balance at `latest`, which should have the
          # withdrawal applied.
          let r = env.client.balanceAt(address)
          #r.ExpectationDescription = fmt.Sprintf(`
          #  Requested balance for account %s on "latest" block
          #  after engine_forkchoiceUpdatedV2, expecting balance to
          #  be equal to value on latest payload (%d), since the new payload
          #  has not yet been applied.
          #  `,
          #  addr,
          #  env.clMock.LatestExecutedPayload.Number,
          #)
          let expectedAccountBalance = ws.wdHistory.getExpectedAccountBalance(
              address,
              env.clMock.latestExecutedPayload.blockNumber.uint64)

          r.expectBalanceEqual(expectedAccountBalance)

        let wds = ws.wdHistory.getWithdrawals(env.clMock.latestExecutedPayload.blockNumber.uint64)
        let expectedWithdrawalsRoot = Opt.some(calcWithdrawalsRoot(wds.list))

        # Check the correct withdrawal root on `latest` block
        let r = env.client.latestHeader()
        #r.ExpectationDescription = fmt.Sprintf(`
        #    Requested "latest" block after engine_forkchoiceUpdatedV2,
        #    to verify withdrawalsRoot with the following withdrawals:
        #    %s`, jsWithdrawals)
        r.expectWithdrawalsRoot(expectedWithdrawalsRoot)

        let res = ws.verifyContractsStorage(env)
        testCond res.isOk:
          error "verifyContractsStorage error", msg=res.error
      return true
  ))
  testCond pbRes

  # Iterate over balance history of withdrawn accounts using RPC and
  # check that the balances match expected values.
  # Also check one block before the withdrawal took place, verify that
  # withdrawal has not been updated.
  if not ws.skipBaseVerifications:
    let maxBlock = env.clMock.latestExecutedPayload.blockNumber.uint64
    for bn in 0..maxBlock:
      let res = ws.wdHistory.verifyWithdrawals(bn, Opt.some(bn), env.client)
      testCond res.isOk:
        error "verify wd error", msg=res.error

      # Check the correct withdrawal root on past blocks
      let r = env.client.headerByNumber(bn)
      var expectedWithdrawalsRoot: Opt[common.Hash32]
      if bn >= ws.forkHeight.uint64:
        let wds = ws.wdHistory.getWithdrawals(bn)
        expectedWithdrawalsRoot = Opt.some(calcWithdrawalsRoot(wds.list))

      #r.ExpectationDescription = fmt.Sprintf(`
      #      Requested block %d to verify withdrawalsRoot with the
      #      following withdrawals:
      #      %s`, block, jsWithdrawals)
      r.expectWithdrawalsRoot(expectedWithdrawalsRoot)

    # Verify on `latest`
    let bnu = env.clMock.latestExecutedPayload.blockNumber.uint64
    let res = ws.wdHistory.verifyWithdrawals(bnu, Opt.none(uint64), env.client)
    testCond res.isOk:
      error "verify wd error", msg=res.error

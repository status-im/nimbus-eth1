import
  std/[times, options],
  stint,
  chronicles,
  chronos,
  stew/byteutils,
  nimcrypto/sysrand,
  web3/ethtypes,
  ./wd_history,
  ../helper,
  ../test_env,
  ../engine_client,
  ../types,
  ../../../tools/common/helpers,
  ../../../nimbus/common/common,
  ../../../nimbus/utils/utils,
  ../../../nimbus/common/chain_config,
  ../../../nimbus/beacon/execution_types,
  ../../../nimbus/beacon/web3_eth_conv

type
  WDBaseSpec* = ref object of BaseSpec
    timeIncrements*:     int          # Timestamp increments per block throughout the test
    wdForkHeight*:       int          # Withdrawals activation fork height
    wdBlockCount*:       int          # Number of blocks on and after withdrawals fork activation
    wdPerBlock*:         int          # Number of withdrawals per block
    wdAbleAccountCount*: int          # Number of accounts to withdraw to (round-robin)
    wdHistory*:          WDHistory    # Internal withdrawals history that keeps track of all withdrawals
    wdAmounts*:          seq[uint64]  # Amounts of withdrawn wei on each withdrawal (round-robin)
    txPerBlock*:         Option[int]  # Amount of test transactions to include in withdrawal blocks
    testCorrupedHashPayloads*: bool   # Send a valid payload with corrupted hash
    skipBaseVerifications*:    bool   # For code reuse of the base spec procedure

  WithdrawalsForBlock = object
    wds: seq[Withdrawal]
    nextIndex: int

const
  GenesisTimestamp = 0x1234
  WARM_COINBASE_ADDRESS = hexToByteArray[20]("0x0101010101010101010101010101010101010101")
  PUSH0_ADDRESS         = hexToByteArray[20]("0x0202020202020202020202020202020202020202")
  MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK* = 16
  TX_CONTRACT_ADDRESSES = [
    WARM_COINBASE_ADDRESS,
    PUSH0_ADDRESS,
  ]

# Get the per-block timestamp increments configured for this test
func getBlockTimeIncrements(ws: WDBaseSpec): int =
  if ws.timeIncrements == 0:
    return 1
  ws.timeIncrements

# Timestamp delta between genesis and the withdrawals fork
func getWithdrawalsGenesisTimeDelta(ws: WDBaseSpec): int =
  ws.wdForkHeight * ws.getBlockTimeIncrements()

# Calculates Shanghai fork timestamp given the amount of blocks that need to be
# produced beforehand.
func getWithdrawalsForkTime(ws: WDBaseSpec): int =
  GenesisTimestamp + ws.getWithdrawalsGenesisTimeDelta()

# Generates the fork config, including withdrawals fork timestamp.
func getForkConfig*(ws: WDBaseSpec): ChainConfig =
  result = getChainConfig("Shanghai")
  result.shanghaiTime = some(ws.getWithdrawalsForkTime().fromUnix)

# Get the start account for all withdrawals.
func getWithdrawalsStartAccount*(ws: WDBaseSpec): UInt256 =
  0x1000.u256

func toAddress(x: UInt256): EthAddress =
  var mm = x.toByteArrayBE
  copyMem(result[0].addr, mm[11].addr, 20)

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

func getWithdrawableAccountCount(ws: WDBaseSpec):int =
  if ws.wdAbleAccountCount == 0:
    # Withdraw to MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK accounts by default
    return MAINNET_MAX_WITHDRAWAL_COUNT_PER_BLOCK
  return ws.wdAbleAccountCount

# Append the accounts we are going to withdraw to, which should also include
# bytecode for testing purposes.
func getGenesis*(ws: WDBaseSpec, param: NetworkParams): NetworkParams =
  # Remove PoW altogether
  param.genesis.difficulty = 0.u256
  param.config.terminalTotalDifficulty = some(0.u256)
  param.config.clique = CliqueOptions()
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

  param

func getTransactionCountPerPayload(ws: WDBaseSpec): int =
  ws.txPerBlock.get(16)

proc verifyContractsStorage(ws: WDBaseSpec, t: TestEnv): Result[void, string] =
  if ws.getTransactionCountPerPayload() < TX_CONTRACT_ADDRESSES.len:
    return

  # Assume that forkchoice updated has been already sent
  let
    latestPayloadNumber = t.clMock.latestExecutedPayload.blockNumber.uint64.u256
    r = t.rpcClient.storageAt(WARM_COINBASE_ADDRESS, latestPayloadNumber, latestPayloadNumber)
    p = t.rpcClient.storageAt(PUSH0_ADDRESS, 0.u256, latestPayloadNumber)

  if latestPayloadNumber.truncate(int) >= ws.wdForkHeight:
    # Shanghai
    r.expectStorageEqual(WARM_COINBASE_ADDRESS, 100.u256)    # WARM_STORAGE_READ_COST
    p.expectStorageEqual(PUSH0_ADDRESS, latestPayloadNumber) # tx succeeded
  else:
    # Pre-Shanghai
    r.expectStorageEqual(WARM_COINBASE_ADDRESS, 2600.u256) # COLD_ACCOUNT_ACCESS_COST
    p.expectStorageEqual(PUSH0_ADDRESS, 0.u256)            # tx must've failed

  ok()

# Changes the CL Mocker default time increments of 1 to the value specified
# in the test spec.
proc configureCLMock*(ws: WDBaseSpec, cl: CLMocker) =
  cl.blockTimestampIncrement = some(ws.getBlockTimeIncrements())

# Number of blocks to be produced (not counting genesis) before withdrawals
# fork.
func getPreWithdrawalsBlockCount*(ws: WDBaseSpec): int =
  if ws.wdForkHeight == 0:
    0
  else:
    ws.wdForkHeight - 1

# Number of payloads to be produced (pre and post withdrawals) during the entire test
func getTotalPayloadCount(ws: WDBaseSpec): int =
  ws.getPreWithdrawalsBlockCount() + ws.wdBlockCount

# Generates a list of withdrawals based on current configuration
func generateWithdrawalsForBlock(ws: WDBaseSpec, nextIndex: int, startAccount: UInt256): WithdrawalsForBlock =
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
proc execute*(ws: WDBaseSpec, t: TestEnv): bool =
  result = true

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Check if we have pre-Shanghai blocks
  if ws.getWithdrawalsForkTime() > GenesisTimestamp:
    # Check `latest` during all pre-shanghai blocks, none should
    # contain `withdrawalsRoot`, including genesis.

    # Genesis should not contain `withdrawalsRoot` either
    var h: common.BlockHeader
    let r = t.rpcClient.latestHeader(h)
    testCond r.isOk:
      error "failed to ge latest header", msg=r.error
    testCond h.withdrawalsRoot.isNone:
      error "genesis should not contains wdsRoot"
  else:
    # Genesis is post shanghai, it should contain EmptyWithdrawalsRoot
    var h: common.BlockHeader
    let r = t.rpcClient.latestHeader(h)
    testCond r.isOk:
      error "failed to ge latest header", msg=r.error
    testCond h.withdrawalsRoot.isSome:
      error "genesis should contains wdsRoot"
    testCond h.withdrawalsRoot.get == EMPTY_ROOT_HASH:
      error "genesis should contains wdsRoot==EMPTY_ROOT_HASH"

  # Produce any blocks necessary to reach withdrawals fork
  var pbRes = t.clMock.produceBlocks(ws.getPreWithdrawalsBlockCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =

      # Send some transactions
      let numTx = ws.getTransactionCountPerPayload()
      for i in 0..<numTx:
        let destAddr = TX_CONTRACT_ADDRESSES[i mod TX_CONTRACT_ADDRESSES.len]

        let ok = t.sendNextTx(BaseTx(
            recipient: some(destAddr),
            amount:    1.u256,
            txType:    ws.txType,
            gasLimit:  75000.GasInt,
        ))

        testCond ok:
          error "Error trying to send transaction"

      if not ws.skipBaseVerifications:
        # Try to send a ForkchoiceUpdatedV2 with non-null
        # withdrawals before Shanghai
        var r = t.rpcClient.forkchoiceUpdatedV2(
          ForkchoiceStateV1(
            headBlockHash: w3Hash t.clMock.latestHeader,
          ),
          some(PayloadAttributes(
            timestamp:             w3Qty(t.clMock.latestHeader.timestamp, ws.getBlockTimeIncrements()),
            prevRandao:            w3PrevRandao(),
            suggestedFeeRecipient: w3Address(),
            withdrawals:           some(newSeq[WithdrawalV1]()),
          ))
        )
        #r.ExpectationDescription = "Sent pre-shanghai Forkchoice using ForkchoiceUpdatedV2 + Withdrawals, error is expected"
        r.expectErrorCode(engineApiInvalidParams)

        # Send a valid Pre-Shanghai request using ForkchoiceUpdatedV2
        # (clMock uses V1 by default)
        r = t.rpcClient.forkchoiceUpdatedV2(
          ForkchoiceStateV1(
            headBlockHash: w3Hash t.clMock.latestHeader,
          ),
          some(PayloadAttributes(
            timestamp:             w3Qty(t.clMock.latestHeader.timestamp, ws.getBlockTimeIncrements()),
            prevRandao:            w3PrevRandao(),
            suggestedFeeRecipient: w3Address(),
            withdrawals:           none(seq[WithdrawalV1]),
          ))
        )
        #r.ExpectationDescription = "Sent pre-shanghai Forkchoice ForkchoiceUpdatedV2 + null withdrawals, no error is expected"
        r.expectNoError()

      return true
    ,
    onGetPayload: proc(): bool =
      if not ws.skipBaseVerifications:
        # Try to get the same payload but use `engine_getPayloadV2`

        let g = t.rpcClient.getPayloadV2(t.clMock.nextPayloadID)
        g.expectPayload(t.clMock.latestPayloadBuilt)

        # Send produced payload but try to include non-nil
        # `withdrawals`, it should fail.
        let emptyWithdrawalsList = newSeq[Withdrawal]()
        let customizer = CustomPayload(
          withdrawals: some(emptyWithdrawalsList),
          beaconRoot: ethHash t.clMock.latestPayloadAttributes.parentBeaconBlockRoot
        )
        let payloadPlusWithdrawals = customizePayload(t.clMock.latestPayloadBuilt, customizer)
        var r = t.rpcClient.newPayloadV2(payloadPlusWithdrawals.V1V2)
        #r.ExpectationDescription = "Sent pre-shanghai payload using NewPayloadV2+Withdrawals, error is expected"
        r.expectErrorCode(engineApiInvalidParams)

        # Send valid ExecutionPayloadV1 using engine_newPayloadV2
        r = t.rpcClient.newPayloadV2(t.clMock.latestPayloadBuilt.V1V2)
        #r.ExpectationDescription = "Sent pre-shanghai payload using NewPayloadV2, no error is expected"
        r.expectStatus(valid)
      return true
    ,
    onNewPayloadBroadcast: proc(): bool =
      if not ws.skipBaseVerifications:
        # We sent a pre-shanghai FCU.
        # Keep expecting `nil` until Shanghai.
        var h: common.BlockHeader
        let r = t.rpcClient.latestHeader(h)
        #r.ExpectationDescription = "Requested "latest" block expecting block to contain
        #" withdrawalRoot=nil, because (block %d).timestamp < shanghaiTime
        r.expectWithdrawalsRoot(h, none(common.Hash256))
      return true
    ,
    onForkchoiceBroadcast: proc(): bool =
      if not ws.skipBaseVerifications:
        let r = ws.verifyContractsStorage(t)
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

  pbRes = t.clMock.produceBlocks(ws.wdBlockCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      if not ws.skipBaseVerifications:
        # Try to send a PayloadAttributesV1 with null withdrawals after
        # Shanghai
        let r = t.rpcClient.forkchoiceUpdatedV2(
          ForkchoiceStateV1(
            headBlockHash: w3Hash t.clMock.latestHeader,
          ),
          some(PayloadAttributes(
            timestamp:             w3Qty(t.clMock.latestHeader.timestamp, ws.getBlockTimeIncrements()),
            prevRandao:            w3PrevRandao(),
            suggestedFeeRecipient: w3Address(),
            withdrawals:           none(seq[WithdrawalV1]),
          ))
        )
        #r.ExpectationDescription = "Sent shanghai fcu using PayloadAttributesV1, error is expected"
        r.expectErrorCode(engineApiInvalidParams)

      # Send some withdrawals
      let wfb = ws.generateWithdrawalsForBlock(nextIndex, startAccount)
      t.clMock.nextWithdrawals = some(w3Withdrawals wfb.wds)
      ws.wdHistory.put(t.clMock.currentPayloadNumber, wfb.wds)

      # Send some transactions
      let numTx = ws.getTransactionCountPerPayload()
      for i in 0..<numTx:
        let destAddr = TX_CONTRACT_ADDRESSES[i mod TX_CONTRACT_ADDRESSES.len]

        let ok = t.sendNextTx(BaseTx(
            recipient: some(destAddr),
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
        let customizer = CustomPayload(
          removeWithdrawals: true,
          beaconRoot: ethHash t.clMock.latestPayloadAttributes.parentBeaconBlockRoot
        )
        let nilWithdrawalsPayload = customizePayload(t.clMock.latestPayloadBuilt, customizer)
        let r = t.rpcClient.newPayloadV2(nilWithdrawalsPayload.V1V2)
        #r.ExpectationDescription = "Sent shanghai payload using ExecutionPayloadV1, error is expected"
        r.expectErrorCode(engineApiInvalidParams)

        # Verify the list of withdrawals returned on the payload built
        # completely matches the list provided in the
        # engine_forkchoiceUpdatedV2 method call
        let res = ws.wdHistory.get(t.clMock.currentPayloadNumber)
        doAssert(res.isOk, "withdrawals sent list was not saved")

        let sentList = res.get
        let wdList = t.clMock.latestPayloadBuilt.withdrawals.get
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
        let addrList = ws.wdHistory.getAddressesWithdrawnOnBlock(t.clMock.latestExecutedPayload.blockNumber.uint64)
        for address in addrList:
          # Test balance at `latest`, which should not yet have the
          # withdrawal applied.
          let expectedAccountBalance = ws.wdHistory.getExpectedAccountBalance(
            address,
            t.clMock.latestExecutedPayload.blockNumber.uint64-1)

          let r = t.rpcClient.balanceAt(address)
          #r.ExpectationDescription = fmt.Sprintf(`
          #  Requested balance for account %s on "latest" block
          #  after engine_newPayloadV2, expecting balance to be equal
          #  to value on previous block (%d), since the new payload
          #  has not yet been applied.
          #  `,
          #  addr,
          #  t.clMock.LatestExecutedPayload.Number-1,
          #)
          r.expectBalanceEqual(expectedAccountBalance)

        if ws.testCorrupedHashPayloads:
          var payload = t.clMock.latestExecutedPayload

          # Corrupt the hash
          var randomHash: common.Hash256
          testCond randomBytes(randomHash.data) == 32
          payload.blockHash = w3Hash randomHash

          # On engine_newPayloadV2 `INVALID_BLOCK_HASH` is deprecated
          # in favor of reusing `INVALID`
          let n = t.rpcClient.newPayloadV2(payload.V1V2)
          n.expectStatus(invalid)
      return true
    ,
    onForkchoiceBroadcast: proc(): bool =
      # Check withdrawal addresses and verify withdrawal balances
      # have been applied
      if not ws.skipBaseVerifications:
        let addrList = ws.wdHistory.getAddressesWithdrawnOnBlock(t.clMock.latestExecutedPayload.blockNumber.uint64)
        for address in addrList:
          # Test balance at `latest`, which should have the
          # withdrawal applied.
          let r = t.rpcClient.balanceAt(address)
          #r.ExpectationDescription = fmt.Sprintf(`
          #  Requested balance for account %s on "latest" block
          #  after engine_forkchoiceUpdatedV2, expecting balance to
          #  be equal to value on latest payload (%d), since the new payload
          #  has not yet been applied.
          #  `,
          #  addr,
          #  t.clMock.LatestExecutedPayload.Number,
          #)
          let expectedAccountBalance = ws.wdHistory.getExpectedAccountBalance(
              address,
              t.clMock.latestExecutedPayload.blockNumber.uint64)

          r.expectBalanceEqual(expectedAccountBalance)

        let wds = ws.wdHistory.getWithdrawals(t.clMock.latestExecutedPayload.blockNumber.uint64)
        let expectedWithdrawalsRoot = some(calcWithdrawalsRoot(wds.list))

        # Check the correct withdrawal root on `latest` block
        var h: common.BlockHeader
        let r = t.rpcClient.latestHeader(h)
        #r.ExpectationDescription = fmt.Sprintf(`
        #    Requested "latest" block after engine_forkchoiceUpdatedV2,
        #    to verify withdrawalsRoot with the following withdrawals:
        #    %s`, jsWithdrawals)
        r.expectWithdrawalsRoot(h, expectedWithdrawalsRoot)

        let res = ws.verifyContractsStorage(t)
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
    let maxBlock = t.clMock.latestExecutedPayload.blockNumber.uint64
    for bn in 0..maxBlock:
      let res = ws.wdHistory.verifyWithdrawals(bn, some(bn.u256), t.rpcClient)
      testCond res.isOk:
        error "verify wd error", msg=res.error

      # Check the correct withdrawal root on past blocks
      var h: common.BlockHeader
      let r = t.rpcClient.headerByNumber(bn, h)

      var expectedWithdrawalsRoot: Option[common.Hash256]
      if bn >= ws.wdForkHeight.uint64:
        let wds = ws.wdHistory.getWithdrawals(bn)
        expectedWithdrawalsRoot = some(calcWithdrawalsRoot(wds.list))

      #r.ExpectationDescription = fmt.Sprintf(`
      #      Requested block %d to verify withdrawalsRoot with the
      #      following withdrawals:
      #      %s`, block, jsWithdrawals)
      r.expectWithdrawalsRoot(h, expectedWithdrawalsRoot)

    # Verify on `latest`
    let bnu = t.clMock.latestExecutedPayload.blockNumber.uint64
    let res = ws.wdHistory.verifyWithdrawals(bnu, none(UInt256), t.rpcClient)
    testCond res.isOk:
      error "verify wd error", msg=res.error

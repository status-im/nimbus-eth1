import
  std/strutils,
  ./engine_spec

type
  PrevRandaoTransactionTest* = ref object of EngineSpec
    blockCount int

method withMainFork(cs: PrevRandaoTransactionTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: PrevRandaoTransactionTest): string =
  return "PrevRandao Opcode Transactions Test (%s)", cs.txType)
)

method execute(cs: PrevRandaoTransactionTest, env: TestEnv): bool =
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Create a single block to not having to build on top of genesis
  env.clMock.produceSingleBlock(BlockProcessCallbacks())

  startBlockNumber = env.clMock.latestHeader.blockNumber.Uint64() + 1

  # Send transactions in PoS, the value of the storage in these blocks must match the prevRandao value
  var (
    blockCount     = 10
    currentTxIndex = 0
    txs            = make([]typ.Transaction, 0)
  )
  if cs.blockCount > 0 (
    blockCount = cs.blockCount
  )
  env.clMock.produceBlocks(blockCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      tx, err = env.sendNextTx(
        t.TestContext,
        t.Engine,
        &BaseTx(
          recipient:  prevRandaoContractAddr,
          amount:     big0,
          payload:    nil,
          txType:     cs.txType,
          gasLimit:   75000,
        ),
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", t.TestName, err)
      )
      txs = append(txs, tx)
      currentTxIndex++
    ),
    onForkchoiceBroadcast: proc(): bool =
      # Check the transaction tracing, which is client specific
      expectedPrevRandao = env.clMock.prevRandaoHistory[env.clMock.latestHeader.blockNumber.Uint64()+1]
      ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
      defer cancel()
      if err = DebugPrevRandaoTransaction(ctx, t.Client.RPC(), t.Client.Type, txs[currentTxIndex-1],
        &expectedPrevRandao); err != nil (
        fatal "Error during transaction tracing: %v", t.TestName, err)
      )
    ),
  ))

  for i = uint64(startBlockNumber); i <= env.clMock.latestExecutedPayload.blockNumber; i++ (
    checkPrevRandaoValue(t, env.clMock.prevRandaoHistory[i], i)
  )
)

func checkPrevRandaoValue(t *test.Env, expectedPrevRandao common.Hash, blockNumber uint64) (
  storageKey = common.Hash256()
  storageKey[31] = byte(blockNumber)
  r = env.engine.client.TestStorageAt(globals.PrevRandaoContractAddr, storageKey, nil)
  r.ExpectStorageEqual(expectedPrevRandao)
)

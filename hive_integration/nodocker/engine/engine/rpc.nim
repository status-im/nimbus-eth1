import
  std/strutils,
  ./engine_spec

type
  BlockStatusRPCcheckType = enum
    LatestOnNewPayload            = "Latest Block on NewPayload"
    LatestOnHeadblockHash         = "Latest Block on HeadblockHash Update"
    SafeOnSafeblockHash           = "Safe Block on SafeblockHash Update"
    FinalizedOnFinalizedblockHash = "Finalized Block on FinalizedblockHash Update"

type
  BlockStatus* = ref object of EngineSpec
    checkType: BlockStatusRPCcheckType
    # TODO: Syncing   bool

method withMainFork(cs: BlockStatus, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: BlockStatus): string =
  "RPC" & $b.checkType

# Test to verify Block information available at the Eth RPC after NewPayload/ForkchoiceUpdated
method execute(cs: BlockStatus, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS Block
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  case b.checkType
  of SafeOnSafeblockHash, FinalizedOnFinalizedblockHash:
    var number *big.Int
    if b.checkType == SafeOnSafeblockHash:
      number = Safe
    else:
      number = Finalized

    p = env.engine.client.TestHeaderByNumber(number)
    p.expectError()
  )

  # Produce blocks before starting the test
  env.clMock.produceBlocks(5, BlockProcessCallbacks())

  var tx typ.Transaction
  callbacks = BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      let tc = BaseTx(
          recipient:  &ZeroAddr,
          amount:     1.u256,
          payload:    nil,
          txType:     cs.txType,
          gasLimit:   75000,
          ForkConfig: t.ForkConfig,
        ),

      tx, err = env.sendNextTx(
      )
      if err != nil (
        fatal "Error trying to send transaction: %v", err)
      )
    ),
  )

  switch b.checkType (
  case LatestOnNewPayload:
    callbacks.onGetPayload = proc(): bool
      r = env.engine.client.latestHeader()
      r.expectHash(env.clMock.latestForkchoice.headblockHash)

      s = env.engine.client.TestBlockNumber()
      s.ExpectNumber(env.clMock.latestHeadNumber.Uint64())

      p = env.engine.client.latestHeader()
      p.expectHash(env.clMock.latestForkchoice.headblockHash)

      # Check that the receipt for the transaction we just sent is still not available
      q = env.engine.client.txReceipt(tx.Hash())
      q.expectError()
    )
  case LatestOnHeadblockHash:
    callbacks.onForkchoiceBroadcast = proc(): bool
      r = env.engine.client.latestHeader()
      r.expectHash(env.clMock.latestForkchoice.headblockHash)

      s = env.engine.client.txReceipt(tx.Hash())
      s.ExpectTransactionHash(tx.Hash())
    )
  case SafeOnSafeblockHash:
    callbacks.onSafeBlockChange = proc(): bool
      r = env.engine.client.TestHeaderByNumber(Safe)
      r.expectHash(env.clMock.latestForkchoice.safeblockHash)
    )
  case FinalizedOnFinalizedblockHash:
    callbacks.onFinalizedBlockChange = proc(): bool
      r = env.engine.client.TestHeaderByNumber(Finalized)
      r.expectHash(env.clMock.latestForkchoice.finalizedblockHash)
    )
  )

  # Perform the test
  env.clMock.produceSingleBlock(callbacks)
)

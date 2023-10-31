import
  std/strutils,
  ./engine_spec

type
  SuggestedFeeRecipientTest* = ref object of EngineSpec
    transactionCount: int

method withMainFork(cs: SuggestedFeeRecipientTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: SuggestedFeeRecipientTest): string =
  "Suggested Fee Recipient Test " & $cs.txType

method execute(cs: SuggestedFeeRecipientTest, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Create a single block to not having to build on top of genesis
  testCond env.clMock.produceSingleBlock(BlockProcessCallbacks())

  # Verify that, in a block with transactions, fees are accrued by the suggestedFeeRecipient
  let
    feeRecipient = EthAddress.randomBytes()
    txRecipient = EthAddress.randomBytes()

  # Send multiple transactions
  for i = 0; i < cs.transactionCount; i++ (
    _, err = env.sendNextTx(
      t.TestContext,
      t.Engine,
      &BaseTx(
        recipient:  &txRecipient,
        amount:     big0,
        payload:    nil,
        txType:     cs.txType,
        gasLimit:   75000,
      ),
    )
    if err != nil (
      fatal "Error trying to send transaction: %v", t.TestName, err)
    )
  )
  # Produce the next block with the fee recipient set
  env.clMock.nextFeeRecipient = feeRecipient
  env.clMock.produceSingleBlock(BlockProcessCallbacks())

  # Calculate the fees and check that they match the balance of the fee recipient
  r = env.engine.client.TestBlockByNumber(Head)
  r.ExpecttransactionCountEqual(cs.transactionCount)
  r.ExpectCoinbase(feeRecipient)
  blockIncluded = r.Block

  feeRecipientFees = big.NewInt(0)
  for _, tx = range blockIncluded.Transactions() (
    effGasTip, err = tx.EffectiveGasTip(blockIncluded.BaseFee())
    if err != nil (
      fatal "unable to obtain EffectiveGasTip: %v", t.TestName, err)
    )
    ctx, cancel = context.WithTimeout(t.TestContext, globals.RPCTimeout)
    defer cancel()
    receipt, err = t.Eth.TransactionReceipt(ctx, tx.Hash())
    if err != nil (
      fatal "unable to obtain receipt: %v", t.TestName, err)
    )
    feeRecipientFees = feeRecipientFees.Add(feeRecipientFees, effGasTip.Mul(effGasTip, big.NewInt(int64(receipt.GasUsed))))
  )

  s = env.engine.client.TestBalanceAt(feeRecipient, nil)
  s.expectBalanceEqual(feeRecipientFees)

  # Produce another block without txns and get the balance again
  env.clMock.nextFeeRecipient = feeRecipient
  env.clMock.produceSingleBlock(BlockProcessCallbacks())

  s = env.engine.client.TestBalanceAt(feeRecipient, nil)
  s.expectBalanceEqual(feeRecipientFees)
)

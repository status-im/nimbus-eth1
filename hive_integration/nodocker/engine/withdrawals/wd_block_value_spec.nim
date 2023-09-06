import
  stint,
  chronicles,
  eth/common/eth_types_rlp,
  ./wd_base_spec,
  ../test_env,
  ../engine_client,
  ../types,
  ../../../nimbus/transaction

type
  BlockValueSpec* = ref object of WDBaseSpec

proc execute*(ws: BlockValueSpec, env: TestEnv): bool =
  WDBaseSpec(ws).skipBaseVerifications = true
  testCond WDBaseSpec(ws).execute(env)

  # Get the latest block and the transactions included
  var blk: EthBlock
  let b = env.client.latestBlock(blk)
  b.expectNoError()

  var totalValue: UInt256
  testCond blk.txs.len > 0:
    error "No transactions included in latest block"

  for tx in blk.txs:
    let txHash = rlpHash(tx)
    let r = env.client.txReceipt(txHash)
    r.expectNoError()

    let
      rec = r.get
      txTip = tx.effectiveGasTip(blk.header.baseFee)

    totalValue += txTip.uint64.u256 * rec.gasUsed.u256

  doAssert(env.cLMock.latestBlockValue.isSome)
  testCond totalValue == env.cLMock.latestBlockValue.get:
    error "Unexpected block value returned on GetPayloadV2",
      expect=totalValue,
      get=env.cLMock.latestBlockValue.get
  return true

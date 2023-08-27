import
  std/typetraits,
  chronos,
  chronicles,
  eth/common/eth_types_rlp,
  ./wd_base_spec,
  ../test_env,
  ../engine_client,
  ../types,
  ../helper,
  ../../../nimbus/constants,
  ../../../nimbus/beacon/execution_types,
  ../../../nimbus/beacon/web3_eth_conv

# EIP-3860 Shanghai Tests:
# Send transactions overflowing the MAX_INITCODE_SIZE
# limit set in EIP-3860, before and after the Shanghai
# fork.
type
  MaxInitcodeSizeSpec* = ref object of WDBaseSpec
    overflowMaxInitcodeTxCountBeforeFork*: uint64
    overflowMaxInitcodeTxCountAfterFork *: uint64

const
  MAX_INITCODE_SIZE = EIP3860_MAX_INITCODE_SIZE

proc execute*(ws: MaxInitcodeSizeSpec, t: TestEnv): bool =
  testCond waitFor t.clMock.waitForTTD()

  var
    invalidTxCreator = BigInitcodeTx(
      initcodeLength: MAX_INITCODE_SIZE + 1,
      gasLimit: 2000000,
    )

    validTxCreator = BigInitcodeTx(
      initcodeLength: MAX_INITCODE_SIZE,
      gasLimit: 2000000,
    )

  if ws.overflowMaxInitcodeTxCountBeforeFork > 0:
    doAssert(ws.getPreWithdrawalsBlockCount > 0, "invalid test configuration")
    for i in 0..<ws.overflowMaxInitcodeTxCountBeforeFork:
      testCond t.sendTx(invalidTxCreator, i):
        error "Error sending max initcode transaction before Shanghai"


  # Produce all blocks needed to reach Shanghai
  info "Blocks until Shanghai", count=ws.getPreWithdrawalsBlockCount
  var txIncluded = 0'u64
  var pbRes = t.clMock.produceBlocks(ws.getPreWithdrawalsBlockCount, BlockProcessCallbacks(
    onGetPayload: proc(): bool =
      info "Got Pre-Shanghai", blockNumber=t.clMock.latestPayloadBuilt.blockNumber.uint64
      txIncluded += t.clMock.latestPayloadBuilt.transactions.len.uint64
      return true
  ))

  testCond pbRes

  # Check how many transactions were included
  if txIncluded == 0 and ws.overflowMaxInitcodeTxCountBeforeFork > 0:
    error "No max initcode txs included before Shanghai. Txs must have been included before the MAX_INITCODE_SIZE limit was enabled"

  # Create a payload, no txs should be included
  pbRes = t.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetPayload: proc(): bool =
      testCond t.clMock.latestPayloadBuilt.transactions.len == 0:
        error "Client included tx exceeding the MAX_INITCODE_SIZE in payload"
      return true
  ))

  testCond pbRes

  # Send transactions after the fork
  for i in txIncluded..<txIncluded + ws.overflowMaxInitcodeTxCountAfterFork:
    let tx = t.makeTx(invalidTxCreator, i)
    testCond not t.sendTx(tx):
      error "Client accepted tx exceeding the MAX_INITCODE_SIZE"

    let res = t.rpcClient.txByHash(rlpHash(tx))
    testCond res.isErr:
      error "Invalid tx was not unknown to the client"

  # Try to include an invalid tx in new payload
  let
    validTx   = t.makeTx(validTxCreator, txIncluded)
    invalidTx = t.makeTx(invalidTxCreator, txIncluded)

  pbRes = t.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      testCond t.sendTx(validTx)
      return true
    ,
    onGetPayload: proc(): bool =
      let validTxBytes = rlp.encode(validTx)
      testCond t.clMock.latestPayloadBuilt.transactions.len == 1:
        error "Client did not include valid tx with MAX_INITCODE_SIZE"

      testCond validTxBytes == distinctBase(t.clMock.latestPayloadBuilt.transactions[0]):
        error "valid Tx bytes mismatch"

      # Customize the payload to include a tx with an invalid initcode
      let customData = CustomPayload(
        beaconRoot: ethHash t.clMock.latestPayloadAttributes.parentBeaconBlockRoot,
        transactions: some( @[invalidTx] ),
      )

      let customPayload = customizePayload(t.clMock.latestPayloadBuilt, customData)
      let res = t.rpcClient.newPayloadV2(customPayload.V1V2)
      res.expectStatus(invalid)
      res.expectLatestValidHash(t.clMock.latestPayloadBuilt.parentHash)

      return true
  ))

  testCond pbRes
  return true

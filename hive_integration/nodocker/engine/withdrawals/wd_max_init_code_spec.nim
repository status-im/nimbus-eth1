# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/typetraits,
  chronos,
  chronicles,
  eth/common/eth_types_rlp,
  ./wd_base_spec,
  ../test_env,
  ../engine_client,
  ../types,
  ../cancun/customizer,
  ../../../../execution_chain/constants,
  web3/execution_types,
  ../../../../execution_chain/beacon/web3_eth_conv

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

proc execute*(ws: MaxInitcodeSizeSpec, env: TestEnv): bool =
  testCond waitFor env.clMock.waitForTTD()

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
      testCond env.sendTx(invalidTxCreator, i):
        error "Error sending max initcode transaction before Shanghai"


  # Produce all blocks needed to reach Shanghai
  info "Blocks until Shanghai", count=ws.getPreWithdrawalsBlockCount
  var txIncluded = 0'u64
  var pbRes = env.clMock.produceBlocks(ws.getPreWithdrawalsBlockCount, BlockProcessCallbacks(
    onGetPayload: proc(): bool =
      info "Got Pre-Shanghai", blockNumber=env.clMock.latestPayloadBuilt.blockNumber.uint64
      txIncluded += env.clMock.latestPayloadBuilt.transactions.len.uint64
      return true
  ))

  testCond pbRes

  # Check how many transactions were included
  if txIncluded == 0 and ws.overflowMaxInitcodeTxCountBeforeFork > 0:
    error "No max initcode txs included before Shanghai. Txs must have been included before the MAX_INITCODE_SIZE limit was enabled"

  # Create a payload, no txs should be included
  pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onGetPayload: proc(): bool =
      testCond env.clMock.latestPayloadBuilt.transactions.len == 0:
        error "Client included tx exceeding the MAX_INITCODE_SIZE in payload"
      return true
  ))

  testCond pbRes

  # Send transactions after the fork
  for i in txIncluded..<txIncluded + ws.overflowMaxInitcodeTxCountAfterFork:
    let tx = env.makeTx(invalidTxCreator, i)
    testCond not env.sendTx(tx):
      error "Client accepted tx exceeding the MAX_INITCODE_SIZE"

    let res = env.client.txByHash(rlpHash(tx))
    testCond res.isErr:
      error "Invalid tx was not unknown to the client"

  # Try to include an invalid tx in new payload
  let
    validTx   = env.makeTx(validTxCreator, txIncluded)
    invalidTx = env.makeTx(invalidTxCreator, txIncluded)

  pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      testCond env.sendTx(validTx)
      return true
    ,
    onGetPayload: proc(): bool =
      let validTxBytes = rlp.encode(validTx)
      testCond env.clMock.latestPayloadBuilt.transactions.len == 1:
        error "Client did not include valid tx with MAX_INITCODE_SIZE"

      testCond validTxBytes == distinctBase(env.clMock.latestPayloadBuilt.transactions[0]):
        error "valid Tx bytes mismatch"

      # Customize the payload to include a tx with an invalid initcode
      let customizer = CustomPayloadData(
        parentBeaconRoot: env.clMock.latestPayloadAttributes.parentBeaconBlockRoot,
        transactions: Opt.some( @[invalidTx.tx] ),
      )

      let customPayload = customizer.customizePayload(env.clMock.latestExecutableData).basePayload
      let res = env.client.newPayloadV2(customPayload.V1V2)
      res.expectStatus(PayloadExecutionStatus.invalid)
      res.expectLatestValidHash(env.clMock.latestPayloadBuilt.parentHash)

      return true
  ))

  testCond pbRes
  return true

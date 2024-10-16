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
  std/strutils,
  chronicles,
  ./engine_spec,
  ../../../../nimbus/transaction

type
  SuggestedFeeRecipientTest* = ref object of EngineSpec
    transactionCount*: int

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
    feeRecipient = Address.randomBytes()
    txRecipient = Address.randomBytes()

  # Send multiple transactions
  for i in 0..<cs.transactionCount:
    let tc = BaseTx(
      recipient:  Opt.some(txRecipient),
      amount:     0.u256,
      txType:     cs.txType,
      gasLimit:   75000,
    )
    let ok = env.sendNextTx(env.engine, tc)
    testCond ok:
      fatal "Error trying to send transaction"

  # Produce the next block with the fee recipient set
  env.clMock.nextFeeRecipient = feeRecipient
  testCond env.clMock.produceSingleBlock(BlockProcessCallbacks())

  # Calculate the fees and check that they match the balance of the fee recipient
  let r = env.engine.client.latestBlock()
  testCond r.isOk:
    error "cannot get latest header", msg=r.error

  let blockIncluded = r.get

  testCond blockIncluded.txs.len == cs.transactionCount:
    error "expect transactions", get=blockIncluded.txs.len, expect=cs.transactionCount

  testCond feeRecipient == blockIncluded.header.coinbase:
    error "expect coinbase",
      get=blockIncluded.header.coinbase,
      expect=feeRecipient

  var feeRecipientFees = 0.u256
  for tx in blockIncluded.txs:
    let effGasTip = tx.effectiveGasTip(blockIncluded.header.baseFeePerGas)

    let r = env.engine.client.txReceipt(tx.rlpHash)
    testCond r.isOk:
      fatal "unable to obtain receipt", msg=r.error

    let receipt = r.get
    feeRecipientFees = feeRecipientFees + effGasTip.u256 * receipt.gasUsed.u256


  var s = env.engine.client.balanceAt(feeRecipient)
  s.expectBalanceEqual(feeRecipientFees)

  # Produce another block without txns and get the balance again
  env.clMock.nextFeeRecipient = feeRecipient
  testCond env.clMock.produceSingleBlock(BlockProcessCallbacks())

  s = env.engine.client.balanceAt(feeRecipient)
  s.expectBalanceEqual(feeRecipientFees)
  return true

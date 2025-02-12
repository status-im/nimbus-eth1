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
  std/strutils,
  eth/common,
  stint,
  chronicles,
  ./step_desc,
  ./helpers,
  ./blobs,
  ../test_env,
  ../tx_sender,
  ../../../../execution_chain/utils/utils

type
  # A step that sends multiple new blobs to the client
  SendBlobTransactions* = ref object of TestStep
    # Number of blob transactions to send before this block's GetPayload request
    transactionCount*: int
    # Blobs per transaction
    blobsPerTransaction*: int
    # Max Data Gas Cost for every blob transaction
    blobTransactionMaxBlobGasCost*: UInt256
    # Gas Fee Cap for every blob transaction
    blobTransactionGasFeeCap*: GasInt
    # Gas Tip Cap for every blob transaction
    blobTransactionGasTipCap*: GasInt
    # Replace transactions
    replaceTransactions*: bool
    # Skip verification of retrieving the tx from node
    skipVerificationFromNode*: bool
    # Account index to send the blob transactions from
    accountIndex*: int
    # Client index to send the blob transactions to
    clientIndex*: int

func getBlobsPerTransaction(step: SendBlobTransactions): int =
  var blobCountPerTx = step.blobsPerTransaction
  if blobCountPerTx == 0:
    blobCountPerTx = 1
  return blobCountPerTx

method execute*(step: SendBlobTransactions, ctx: CancunTestContext): bool =
  # Send a blob transaction
  let blobCountPerTx = step.getBlobsPerTransaction()

  if step.clientIndex >= ctx.env.numEngines:
    error "invalid client index", index=step.clientIndex
    return false

  let engine = ctx.env.engines(step.clientIndex)
  #  Send the blob transactions
  for _ in 0..<step.transactionCount:
    let tc = BlobTx(
      recipient:  Opt.some(DATAHASH_START_ADDRESS),
      gasLimit:   100000.GasInt,
      gasTip:     step.blobTransactionGasTipCap,
      gasFee:     step.blobTransactionGasFeeCap,
      blobGasFee: step.blobTransactionMaxBlobGasCost,
      blobCount:  blobCountPerTx,
      blobID:     ctx.txPool.currentBlobID,
    )

    let sender = ctx.env.accounts(step.accountIndex)
    let res = if step.replaceTransactions:
                ctx.env.replaceTx(sender, engine, tc)
              else:
                ctx.env.sendTx(sender, engine, tc)

    if res.isErr:
      return false

    let blobTx = res.get
    if not step.skipVerificationFromNode:
      let r = verifyTransactionFromNode(engine.client, blobTx.tx)
      if r.isErr:
        error "verify tx from node", msg=r.error
        return false

    let txHash = rlpHash(blobTx)
    ctx.txPool.addBlobTransaction(blobTx)
    ctx.txPool.hashesByIndex[ctx.txPool.currentTxIndex] = txHash
    ctx.txPool.currentTxIndex += 1
    info "Sent blob transaction", txHash=txHash.short
    ctx.txPool.currentBlobID += BlobID(blobCountPerTx)

  return true

method description*(step: SendBlobTransactions): string =
  "SendBlobTransactions: $1 transactions, $2 blobs each, $3 max data gas fee" % [
    $step.transactionCount, $step.getBlobsPerTransaction(), $step.blobTransactionMaxBlobGasCost]

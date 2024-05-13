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
  eth/common,
  chronicles,
  ./step_desc,
  ./helpers,
  ../types,
  ../test_env,
  ../../../../nimbus/utils/utils,
  ../../../../nimbus/sync/protocol

# A step that requests a Transaction hash via P2P and expects the correct full blob tx
type
  DevP2PRequestPooledTransactionHash* = ref object of TestStep
    # Client index to request the transaction hash from
    clientIndex*: int
    # Transaction Index to request
    transactionIndexes*: seq[int]
    # Wait for a new pooled transaction message before actually requesting the transaction
    waitForNewPooledTransaction*: bool

method execute*(step: DevP2PRequestPooledTransactionHash, ctx: CancunTestContext): bool =
  # Get client index's enode
  let env = ctx.env
  doAssert(step.clientIndex < env.numEngines, "invalid client index" & $step.clientIndex)
  let engine = env.engines(step.clientIndex)
  let sec = env.addEngine(false, false)

  engine.connect(sec.node)

  var
    txHashes = newSeq[common.Hash256](step.transactionIndexes.len)
    txs      = newSeq[PooledTransaction](step.transactionIndexes.len)

  for i, txIndex in step.transactionIndexes:
    if not ctx.txPool.hashesByIndex.hasKey(txIndex):
      error "transaction not found", index=step.transactionIndexes[i]
      return false

    txHashes[i] = ctx.txPool.hashesByIndex[txIndex]

    if not ctx.txPool.transactions.hasKey(txHashes[i]):
      error "transaction not found", hash=txHashes[i].short
      return false

    txs[i] = ctx.txPool.transactions[txHashes[i]]

  # Wait for a new pooled transaction message
  if step.waitForNewPooledTransaction:
    let period = chronos.seconds(1)
    var loop = 0

    while loop < 20:
      if sec.numTxsInPool >= txs.len:
        break
      waitFor sleepAsync(period)
      inc loop

    # those txs above should have been relayed to second client
    # when it first connected
    let secTxs = sec.getTxsInPool(txHashes)
    if secTxs.len != txHashes.len:
      error "expected txs from newPooledTxs num mismatch",
        expect=txHashes.len,
        get=secTxs.len
      return false

    for i, secTx in secTxs:
      let secTxBytes = rlp.encode(secTx)
      let localTxBytes = rlp.encode(txs[i])

      if secTxBytes.len != localTxBytes.len:
        error "expected tx from newPooledTxs size mismatch",
          expect=localTxBytes.len,
          get=secTxBytes.len
        return false

      if secTxBytes != localTxBytes:
        error "expected tx from gnewPooledTxs bytes not equal"
        return false

  # Send the request for the pooled transactions
  let peer = sec.peer
  let res = waitFor peer.getPooledTransactions(txHashes)
  if res.isNone:
    error "getPooledTransactions returns none"
    return false

  let remoteTxs = res.get
  if remoteTxs.transactions.len != txHashes.len:
    error "expected txs from getPooledTransactions num mismatch",
      expect=txHashes.len,
      get=remoteTxs.transactions.len
    return false

  for i, remoteTx in remoteTxs.transactions:
    let remoteTxBytes = rlp.encode(remoteTx)
    let localTxBytes = rlp.encode(txs[i])

    if remoteTxBytes.len != localTxBytes.len:
      error "expected tx from getPooledTransactions size mismatch",
        expect=localTxBytes.len,
        get=remoteTxBytes.len
      return false

    if remoteTxBytes != localTxBytes:
      error "expected tx from getPooledTransactions bytes not equal"
      return false

  return true

method description*(step: DevP2PRequestPooledTransactionHash): string =
  "DevP2PRequestPooledTransactionHash: client $1, transaction indexes $1" % [
    $step.clientIndex, $step.transactionIndexes]

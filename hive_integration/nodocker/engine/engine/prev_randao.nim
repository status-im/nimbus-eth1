# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
  ./engine_spec

type
  PrevRandaoTransactionTest* = ref object of EngineSpec
    blockCount*: int

  Shadow = ref object
    startBlockNumber: uint64
    blockCount: int
    currentTxIndex: int
    txs: seq[Transaction]

proc checkPrevRandaoValue(client: RpcClient, expectedPrevRandao: common.Hash256, blockNumber: uint64): bool =
  let storageKey = blockNumber.u256
  let r = client.storageAt(prevRandaoContractAddr, storageKey)
  let expected = UInt256.fromBytesBE(expectedPrevRandao.data)
  r.expectStorageEqual(expected)
  return true

method withMainFork(cs: PrevRandaoTransactionTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: PrevRandaoTransactionTest): string =
  "PrevRandao Opcode Transactions Test ($1)" % [$cs.txType]

method execute(cs: PrevRandaoTransactionTest, env: TestEnv): bool =
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Create a single block to not having to build on top of genesis
  testCond env.clMock.produceSingleBlock(BlockProcessCallbacks())

  var shadow = Shadow(
    startBlockNumber: env.clMock.latestHeader.blockNumber.truncate(uint64) + 1,
    # Send transactions in PoS, the value of the storage in these blocks must match the prevRandao value
    blockCount: 10,
    currentTxIndex: 0,
  )

  if cs.blockCount > 0:
    shadow.blockCount = cs.blockCount

  let pbRes = env.clMock.produceBlocks(shadow.blockCount, BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      let tc = BaseTx(
        recipient:  some(prevRandaoContractAddr),
        amount:     0.u256,
        txType:     cs.txType,
        gasLimit:   75000,
      )
      let tx = env.makeNextTx(tc)
      let ok = env.sendTx(tx)
      testCond ok:
        fatal "Error trying to send transaction"

      shadow.txs.add(tx)
      inc shadow.currentTxIndex
      return true
    ,
    onForkchoiceBroadcast: proc(): bool =
      # Check the transaction tracing, which is client specific
      let expectedPrevRandao = env.clMock.prevRandaoHistory[env.clMock.latestHeader.blockNumber.truncate(uint64)+1]
      let res = debugPrevRandaoTransaction(env.engine.client, shadow.txs[shadow.currentTxIndex-1], expectedPrevRandao)
      testCond res.isOk:
        fatal "Error during transaction tracing", msg=res.error

      return true
  ))
  testCond pbRes

  for i in shadow.startBlockNumber..env.clMock.latestExecutedPayload.blockNumber.uint64:
    if not checkPrevRandaoValue(env.engine.client, env.clMock.prevRandaoHistory[i], i):
      fatal "wrong prev randao", index=i
      return false

  return true

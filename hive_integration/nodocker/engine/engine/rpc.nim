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
  eth/common,
  chronicles,
  ./engine_spec

type
  BlockStatusRPCcheckType* = enum
    LatestOnNewPayload            = "Latest Block on NewPayload"
    LatestOnHeadBlockHash         = "Latest Block on HeadblockHash Update"
    SafeOnSafeBlockHash           = "Safe Block on SafeblockHash Update"
    FinalizedOnFinalizedBlockHash = "Finalized Block on FinalizedblockHash Update"

type
  BlockStatus* = ref object of EngineSpec
    checkType*: BlockStatusRPCcheckType
    # TODO: Syncing   bool

  Shadow = ref object
    txHash: Hash32

method withMainFork(cs: BlockStatus, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: BlockStatus): string =
  "RPC " & $cs.checkType

# Test to verify Block information available at the Eth RPC after NewPayload/ForkchoiceUpdated
method execute(cs: BlockStatus, env: TestEnv): bool =
  # Wait until this client catches up with latest PoS Block
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  if cs.checkType in [SafeOnSafeBlockHash, FinalizedOnFinalizedBlockHash]:
    var number = Finalized
    if cs.checkType == SafeOnSafeBlockHash:
      number = Safe

    let p = env.engine.client.namedHeader(number)
    p.expectError()

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  var shadow = Shadow()
  var callbacks = BlockProcessCallbacks(
    onPayloadProducerSelected: proc(): bool =
      let tc = BaseTx(
        recipient: Opt.some(ZeroAddr),
        amount:     1.u256,
        txType:     cs.txType,
        gasLimit:   75000,
      )

      let tx = env.makeNextTx(tc)
      shadow.txHash = tx.rlpHash
      let ok = env.sendTx(tx)
      testCond ok:
        fatal "Error trying to send transaction"
      return true
  )

  case cs.checkType
  of LatestOnNewPayload:
    callbacks.onGetPayload = proc(): bool =
      let r = env.engine.client.namedHeader(Head)
      r.expectHash(env.clMock.latestForkchoice.headblockHash)

      let s = env.engine.client.blockNumber()
      s.expectNumber(env.clMock.latestHeadNumber.uint64)

      let p = env.engine.client.namedHeader(Head)
      p.expectHash(env.clMock.latestForkchoice.headblockHash)

      # Check that the receipt for the transaction we just sent is still not available
      let q = env.engine.client.txReceipt(shadow.txHash)
      q.expectError()
      return true
  of LatestOnHeadBlockHash:
    callbacks.onForkchoiceBroadcast = proc(): bool =
      let r = env.engine.client.namedHeader(Head)
      r.expectHash(env.clMock.latestForkchoice.headblockHash)
      let s = env.engine.client.txReceipt(shadow.txHash)
      s.expectTransactionHash(shadow.txHash)
      return true
  of SafeOnSafeBlockHash:
    callbacks.onSafeBlockChange = proc(): bool =
      let r = env.engine.client.namedHeader(Safe)
      r.expectHash(env.clMock.latestForkchoice.safeblockHash)
      return true
  of FinalizedOnFinalizedBlockHash:
    callbacks.onFinalizedBlockChange = proc(): bool =
      let r = env.engine.client.namedHeader(Finalized)
      r.expectHash(env.clMock.latestForkchoice.finalizedblockHash)
      return true

  # Perform the test
  testCond env.clMock.produceSingleBlock(callbacks)
  return true

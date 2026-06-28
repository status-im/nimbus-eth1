# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Legacy era1 procs — to be removed once era1 support is dropped.

{.push raises: [].}

import
  chronos,
  chronicles,
  eth/common/[keys, receipts],
  eth/p2p/discoveryv5/random2,
  ../../../execution_chain/history/db/era1_db,
  ../../../execution_chain/history/block_proofs/historical_hashes_accumulator,
  ../../rpc/portal_rpc_client,
  ../../network/history/history_validation,
  ../../network/network_metadata,
  beacon_chain/process_state,
  ./portal_history_bridge_common

proc runBackfillLoopLegacy*(
    bridge: PortalHistoryBridge,
    era1Dir: string,
    startEra: uint64,
    endEra: uint64,
    loop: bool,
) {.async: (raises: [CancelledError]).} =
  let
    mergeBlockNumber = mergeBlockNumber(bridge.cfg.chainId)
    accumulator = loadAccumulator(bridge.network)
    lastEra = min(endEra, accumulator.historicalEpochs.len.uint64 - 1)
    db = Era1DB.new(era1Dir, bridge.network, accumulator, mergeBlockNumber)
  defer:
    db.dispose()

  while true:
    for era in startEra .. lastEra:
      let
        blockStart = Era1(era).startNumber()
        blockEnd = Era1(era).endNumber(mergeBlockNumber)

      info "Gossiping bodies and receipts from era1", era, blockStart, blockEnd

      for blockNumber in blockStart .. blockEnd:
        var blockTuple: BlockTuple
        db.getBlockTuple(blockNumber, blockTuple).isOkOr:
          error "Failed to get block tuple from era1", blockNumber, error
          continue

        await bridge.gossipBlockBody(blockNumber, blockTuple.body)
        await bridge.gossipReceipts(blockNumber, blockTuple.receipts.to(StoredReceipts))

      info "Completed gossiping from era1", era

    if not loop:
      ProcessState.scheduleStop("backfill_complete")
      break

    info "Completed backfill loop, starting over"

proc runBackfillLoopSyncModeLegacy*(
    bridge: PortalHistoryBridge,
    era1Dir: string,
    startEra: uint64,
    endEra: uint64,
    loop: bool,
) {.async: (raises: [CancelledError]).} =
  let
    mergeBlockNumber = mergeBlockNumber(bridge.cfg.chainId)
    rng = newRng()
    accumulator = loadAccumulator(bridge.network)
    lastEra = min(endEra, accumulator.historicalEpochs.len.uint64 - 1)
    db = Era1DB.new(era1Dir, bridge.network, accumulator, mergeBlockNumber)
    blockStart = Era1(startEra).startNumber()
    blockEnd = Era1(lastEra).endNumber(mergeBlockNumber)
    blockNumberQueue = newAsyncQueue[uint64](50)
  defer:
    db.dispose()

  proc blockWorker() {.async: (raises: [CancelledError]).} =
    while true:
      let blockNumber = await blockNumberQueue.popFirst()

      logScope:
        blockNumber = blockNumber

      var blockTuple: BlockTuple
      db.getBlockTuple(blockNumber, blockTuple).isOkOr:
        error "Failed to get block tuple", error
        continue

      block bodyBlock:
        let _ = (await historyGetBlockBody(bridge.portalClient, blockTuple.header)).valueOr:
          debug "Failed to find block body content, gossiping..", error = $error.message
          await bridge.gossipBlockBody(blockNumber, blockTuple.body)
          break bodyBlock

      block receiptsBlock:
        let _ = (await historyGetReceipts(bridge.portalClient, blockTuple.header)).valueOr:
          debug "Failed to find block receipts content, gossiping..",
            error = $error.message
          await bridge.gossipReceipts(
            blockNumber, blockTuple.receipts.to(StoredReceipts)
          )
          break receiptsBlock

  var workers: seq[Future[void]] = @[]
  for i in 0 ..< 50:
    workers.add blockWorker()

  while true:
    for blockNumber in blockStart .. blockEnd:
      if blockNumber mod EPOCH_SIZE == 0:
        info "Backfilling task at block", blockNumber, era = blockNumber div EPOCH_SIZE

      await blockNumberQueue.addLast(blockNumber)

    if not loop:
      ProcessState.scheduleStop("backfill_complete")
      break

    info "Completed backfill loop, starting over"

proc runBackfillLoopAuditModeLegacy*(
    bridge: PortalHistoryBridge, era1Dir: string, startEra: uint64, endEra: uint64
) {.async: (raises: [CancelledError]).} =
  let
    mergeBlockNumber = mergeBlockNumber(bridge.cfg.chainId)
    rng = newRng()
    accumulator = loadAccumulator(bridge.network)
    lastEra = min(endEra, accumulator.historicalEpochs.len.uint64 - 1)
    db = Era1DB.new(era1Dir, bridge.network, accumulator, mergeBlockNumber)
    blockStart = Era1(startEra).startNumber()
    blockEnd = Era1(lastEra).endNumber(mergeBlockNumber)
    blockRange = blockEnd - blockStart
  defer:
    db.dispose()

  var blockTuple: BlockTuple
  while true:
    let blockNumber = blockStart + rng[].rand(blockRange).uint64

    logScope:
      blockNumber = blockNumber

    db.getBlockTuple(blockNumber, blockTuple).isOkOr:
      error "Failed to get block tuple", error
      continue

    block bodyBlock:
      let _ = (await historyGetBlockBody(bridge.portalClient, blockTuple.header)).valueOr:
        info "Failed to find block body content, gossiping..", error = $error
        await bridge.gossipBlockBody(blockNumber, blockTuple.body)
        break bodyBlock

    block receiptsBlock:
      let _ = (await historyGetReceipts(bridge.portalClient, blockTuple.header)).valueOr:
        info "Failed to find block receipts content, gossiping..", error = $error
        await bridge.gossipReceipts(blockNumber, blockTuple.receipts.to(StoredReceipts))
        break receiptsBlock

    await sleepAsync(1.seconds)

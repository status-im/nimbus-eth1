# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  results,
  ./db/core_db,
  # metrics,
  # chronos/timer,
  # std/[strformat, strutils],
  # stew/io2,
  beacon_chain/process_state,
  ./conf,
  ./common,
  ./core/chain

proc running(): bool =
  not ProcessState.stopIt(notice("Shutting down", reason = it))

proc purge*(config: ExecutionClientConf, com: CommonRef) =

  let
    start = com.db.baseTxFrame().getSavedStateBlockNumber()
    begin = com.db.baseTxFrame().getHistoryExpired()
    batchSize = 150'u64
    # last = begin + (batchSize*600)

  notice "Current database at", blockNumber = start
  notice "Purging all block bodies till", start

  var
    txFrame = com.db.baseTxFrame().txFrameBegin()
    currentBlock = begin

  proc checkpoint() =
    txFrame.checkpoint(start, skipSnapshot = true)
    com.db.persist(txFrame)
    txFrame = com.db.baseTxFrame().txFrameBegin()

  
  while running() and currentBlock <= start:
    txFrame.deleteBlockBodyAndReceipts(currentBlock).isOkOr:
      warn "Failed", blkNum=currentBlock, error
    
    if (currentBlock mod batchSize) == 0:
      checkpoint()
      notice "Deletion of blocks persisted", blks=currentBlock 
    
    currentBlock += 1
  
  txFrame.setHistoryExpired(currentBlock)
  checkpoint()
  notice "Completed Purging", blocksExistFrom=currentBlock-1, till=start

  
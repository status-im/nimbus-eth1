# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, sequtils, strformat, times],
  ../../nimbus/[config, chain_config, constants, genesis],
  ../../nimbus/db/db_chain,
  ../../nimbus/p2p/chain,
  ../../nimbus/utils/tx_pool,
  ../../nimbus/utils/tx_pool/tx_perjobapi,
  ./helpers,
  chronos,
  eth/[common, keys, p2p, trie/db],
  stint

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc isOK(rc: ValidationResult): bool =
  rc == ValidationResult.OK

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blockChainForTesting*(network: NetworkID): BaseChainDB =

  result = newBaseChainDB(
    newMemoryDb(),
    id = network,
    params = network.networkParams)

  result.populateProgress
  initializeEmptyDB(result)


proc toTxPool*(
    db: BaseChainDB;                  ## to be modified
    file: string;                     ## input, file and transactions
    getLocal: proc(): bool;           ## input, random function
    getStatus: proc(): TxItemStatus;  ## input, random function
    loadBlocks: int;                  ## load at most this many blocks
    loadTxs: int;                     ## load at most this many transactions
    baseFee = 0u64;                   ## initalise with `baseFee` (unless 0)
    noisy: bool): TxPoolRef =

  var
    txPoolOk = false
    txCount = 0
    chainNo = 0
    chainDB = db.newChain

  doAssert not db.isNil

  block allDone:
    for chain in file.undumpNextGroup:
      let leadBlkNum = chain[0][0].blockNumber
      chainNo.inc
      if leadBlkNum == 0.u256:
        # Verify Genesis
        doAssert chain[0][0] == db.getBlockHeader(0.u256)

      elif leadBlkNum < loadBlocks.u256:
        # Import into block chain
        let (headers,bodies) = (chain[0],chain[1])
        doAssert chainDB.persistBlocks(headers,bodies).isOK
        #for h in chain[0]:
        #  if 0 < h.gasUsed:
        #    echo ">>> #", h.blockNumber,
        #     " gasUsed=", h.gasUsed, " gasLimit=", h.gasLimit
      else:
        # Import transactions
        for inx in 0 ..< chain[0].len:
          let
            blkNum = chain[0][inx].blockNumber
            txs = chain[1][inx].transactions

          # Continue importing up until first non-trivial block
          if not txPoolOk:
            if txs.len < 1:
              # collect empty blocks
              let (headers,bodies) = (@[chain[0][inx]],@[chain[1][inx]])
              doAssert chainDB.persistBlocks(headers,bodies).isOK
              continue
            txPoolOk = true
            result = init(type TxPoolRef, db)
            #let h = result.dbHead
            #echo ">>> #", h.head.blockNumber,
            #    " fork=", h.fork,
            #    " baseFee=", h.baseFee,
            #    " trgGasLimit=", h.trgGasLimit,
            #    " maxGasLimit=", h.maxGasLimit
            if 0 < baseFee:
              result.pjaSetBaseFee(baseFee)

          # Load transactions, one-by-one
          for n in 0 ..< txs.len:
            txCount.inc
            let
              local = getLocal()
              status = getStatus()
              info = &"{txCount} #{blkNum}({chainNo}) "&
                    &"{n}/{txs.len} {localInfo[local]} {statusInfo[status]}"
            noisy.showElapsed(&"insert: local={local} {info}"):
              var tx = txs[n]
              result.pjaAddTx(tx, local, info)
            if loadTxs <= txCount:
              break allDone

  waitFor result.jobCommit


proc toTxPool*(
    db: BaseChainDB;            ## to be modified, initialisier for `TxPool`
    itList: var seq[TxItemRef]; ## import items into new `TxPool` (read only)
    baseFee = 0u64;             ## initalise with `baseFee` (unless 0)
    maxRejects = 0;             ## define size of waste basket (unless 0)
    noisy = true): TxPoolRef =

  doAssert not db.isNil

  result = init(type TxPoolRef, db)
  if 0 < baseFee:
    result.pjaSetBaseFee(baseFee)
  if 0 < maxRejects:
    result.setMaxRejects(maxRejects)

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for item in itList:
      var tx = item.tx
      result.pjaAddTx(tx, item.local, item.info)
  result.pjaFlushRejects
  waitFor result.jobCommit
  doAssert result.count.total == itList.len
  doAssert result.count.rejected == 0


proc toTxPool*(
    db: BaseChainDB;
    itList: seq[TxItemRef];
    baseFee = 0u64;
    maxRejects = 0;
    noisy = true): TxPoolRef =
  var newList = itList
  db.toTxPool(newList, baseFee, maxRejects, noisy)


proc toTxPool*(
    db: BaseChainDB;            ## to be modified, initialisier for `TxPool`
    timeGap: var Time;          ## to be set, time in the middle of time gap
    nRemoteGapItems: var int;   ## to be set, # items before time gap
    itList: var seq[TxItemRef]; ## import items into new `TxPool` (read only)
    baseFee = 0u64;             ## initalise with `baseFee` (unless 0)
    remoteItemsPC = 30;         ## % number if items befor time gap
    delayMSecs = 200;           ## size of time vap
    noisy = true): TxPoolRef =
  ## Variant of `toTxPoolFromSeq()` with a time gap between consecutive
  ## items on the `remote` queue
  doAssert not db.isNil
  doAssert 0 < remoteItemsPC and remoteItemsPC < 100

  result = init(type TxPoolRef, db)
  if 0 < baseFee:
    result.pjaSetBaseFee(baseFee)

  var
    nRemoteItems = 0
    remoteCount = 0
  for item in itList:
    if not item.local:
      nRemoteItems.inc
  let
    delayAt = nRemoteItems * remoteItemsPC div 100
    middleOfTimeGap = initDuration(milliSeconds = delayMSecs div 2)

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for item in itList:
      var tx = item.tx
      result.pjaAddTx(tx, item.local, item.info)
      if not item.local and remoteCount < delayAt:
        remoteCount.inc
        if delayAt == remoteCount:
          nRemoteGapItems = remoteCount
          noisy.say &"time gap after {remoteCount} remote transactions"
          let itemID = item.itemID
          waitFor result.jobCommit
          doAssert result.count.rejected == 0
          timeGap = result.getItem(itemID).value.timeStamp + middleOfTimeGap
          delayMSecs.sleep

  waitFor result.jobCommit
  doAssert result.count.total == itList.len
  doAssert result.count.rejected == 0


proc toItems*(xp: TxPoolRef): seq[TxItemRef] =
  var rList: seq[TxItemRef]
  let itFn = proc(item: TxItemRef): bool =
               rList.add item
               true
  xp.pjaItemsApply(itFn, local = true)
  xp.pjaItemsApply(itFn, local = false)
  waitFor xp.jobCommit
  result = rList


proc setItemStatusFromInfo*(xp: TxPoolRef) =
  for item in xp.toItems:
    # Re-define status from last character of info field
    let w = TxItemStatus.toSeq.filterIt(statusInfo[it][0] == item.info[^1])[0]
    xp.pjaSetStatus(item, w)
  xp.pjaFlushRejects
  waitFor xp.jobCommit

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

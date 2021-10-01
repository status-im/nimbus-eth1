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
  eth/[common, keys, p2p, trie/db],
  stint


proc blockChainForTesting*(network: NetworkID): BaseChainDB =
  let boot = CustomGenesis(
    genesis: network.defaultGenesisBlockForNetwork,
    config:  network.chainConfig)

  result = BaseChainDB(
    db: newMemoryDb(),
    config: boot.config)

  result.populateProgress
  boot.genesis.commit(result)


proc toTxPool*(
    db: BaseChainDB;                  ## to be modified
    file: string;                     ## input, file and transactions
    getLocal: proc(): bool;           ## input, random function
    getStatus: proc(): TxItemStatus;  ## input, random function
    loadBlocks: int;                  ## load at most this many blocks
    loadTxs: int;                     ## load at most this many transactions
    baseFee = 0u64;                   ## initalise with `baseFee` (unless 0)
    maxRejects = 0;                   ## define size of waste basket (unless 0)
    noisy: bool): TxPool =

  var
    txCount = 0
    chainNo = 0
    chainDB = db.newChain

  doAssert not db.isNil

  result.init(db)
  if 0 < baseFee:
    result.txDB.baseFee = baseFee
  if 0 < maxRejects:
    result.setMaxRejects(maxRejects)

  for chain in file.undumpNextGroup:
    let leadBlkNum = chain[0][0].blockNumber
    chainNo.inc
    if leadBlkNum == 0.u256:
      # Verify Genesis
      doAssert chain[0][0] == db.getBlockHeader(0.u256)

    elif leadBlkNum < loadBlocks.u256:
      # Import into block chain
      let (headers,bodies) = (chain[0],chain[1])
      doAssert chainDB.persistBlocks(headers,bodies) == ValidationResult.OK

    else:
      # Import transactions
      for chainInx in 0 ..< chain[0].len:
        # load transactions, one-by-one
        let
          blkNum = chain[0][chainInx].blockNumber
          txs = chain[1][chainInx].transactions
        for n in 0 ..< txs.len:
          txCount.inc
          let
            local = getLocal()
            status = getStatus()
            info = &"{txCount} #{blkNum}({chainNo}) "&
                      &"{n}/{txs.len} {localInfo[local]} {statusInfo[status]}"
          noisy.showElapsed(&"insert: local={local} {info}"):
            var tx = txs[n]
            result.addTx(tx, local, info)
          if loadTxs <= txCount:
            return


proc toTxPool*(
    db: BaseChainDB;            ## to be modified, initialisier for `TxPool`
    itList: var seq[TxItemRef]; ## import items into new `TxPool` (read only)
    baseFee = 0u64;             ## initalise with `baseFee` (unless 0)
    maxRejects = 0;             ## define size of waste basket (unless 0)
    noisy = true): TxPool =

  doAssert not db.isNil

  result.init(db)
  if 0 < baseFee:
    result.txDB.baseFee = baseFee
  if 0 < maxRejects:
    result.setMaxRejects(maxRejects)

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for item in itList:
      var tx = item.tx
      result.addTx(tx, item.local, item.info)
  doAssert result.count.total == itList.len
  doAssert result.flushRejects[0] == 0


proc toTxPool*(
    db: BaseChainDB;
    itList: seq[TxItemRef];
    baseFee = 0u64;
    maxRejects = 0;
    noisy = true): TxPool =
  doAssert not db.isNil
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
    noisy = true): TxPool =
  ## Variant of `toTxPoolFromSeq()` with a time gap between consecutive
  ## items on the `remote` queue

  doAssert not db.isNil
  doAssert 0 < remoteItemsPC and remoteItemsPC < 100

  result.init(db)
  if 0 < baseFee:
    result.txDB.baseFee = baseFee

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
      result.addTx(tx, item.local, item.info)
      if not item.local and remoteCount < delayAt:
        remoteCount.inc
        if delayAt == remoteCount:
          nRemoteGapItems = remoteCount
          noisy.say &"time gap after {remoteCount} remote transactions"
          timeGap = result.get(item.itemID).value.timeStamp + middleOfTimeGap
          delayMSecs.sleep

  doAssert result.count.total == itList.len
  doAssert result.flushRejects[0] == 0


proc toItems*(xp: var TxPool): seq[TxItemRef] =
  var rList: seq[TxItemRef]
  let itFn = proc(item: TxItemRef): bool =
               rList.add item
               true
  xp.itemsApply(itFn, local = true)
  xp.itemsApply(itFn, local = false)
  result = rList


proc setItemStatusFromInfo*(xp: var TxPool) =
  for item in xp.toItems:
    # Re-define status from last character of info field
    let w = TxItemStatus.toSeq.filterIt(statusInfo[it][0] == item.info[^1])[0]
    xp.setStatus(item, w)

# End

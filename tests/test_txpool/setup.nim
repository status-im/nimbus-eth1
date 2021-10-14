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
  std/[os, sequtils, strformat, tables, times],
  ../../nimbus/[config, chain_config, constants, genesis],
  ../../nimbus/db/db_chain,
  ../../nimbus/p2p/chain,
  ../../nimbus/transaction,
  ../../nimbus/utils/[ec_recover, tx_pool],
  ../../nimbus/utils/tx_pool/[tx_item, tx_perjobapi],
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
    accounts: var seq[EthAddress];    ## to be initialsed
    file: string;                     ## input, file and transactions
    getStatus: proc(): TxItemStatus;  ## input, random function
    loadBlocks: int;                  ## load at most this many blocks
    loadTxs: int;                     ## load at most this many transactions
    baseFee = 0.GasPrice;             ## initalise with `baseFee` (unless 0)
    noisy: bool): TxPoolRef =

  var
    txPoolOk = false
    txCount = 0
    chainNo = 0
    chainDB = db.newChain
    senders: Table[EthAddress,bool]

  doAssert not db.isNil

  proc collectAccounts(bodies: seq[BlockBody]) =
    for body in bodies:
      for tx in body.transactions:
        let
          s0 = tx.getSender
          s1 = tx.ecRecover.value
        doAssert s0 == s1
        senders[s0] = true

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
        chain[1].collectAccounts
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
            result = TxPoolRef.init(db)
            if 0 < baseFee:
              result.setBaseFee(baseFee)

          # Load transactions, one-by-one
          for n in 0 ..< txs.len:
            txCount.inc
            let
              status = getStatus()
              info = &"{txCount} #{blkNum}({chainNo}) "&
                     &"{n}/{txs.len} {statusInfo[status]}"
            noisy.showElapsed(&"insert: {info}"):
              var tx = txs[n]
              result.pjaAddTx(tx, info)
            if loadTxs <= txCount:
              break allDone

  waitFor result.jobCommit
  accounts = toSeq(senders.keys)


proc toTxPool*(
    db: BaseChainDB;            ## to be modified, initialisier for `TxPool`
    itList: var seq[TxItemRef]; ## import items into new `TxPool` (read only)
    baseFee = 0.GasPrice;       ## initalise with `baseFee` (unless 0)
    noisy = true): TxPoolRef =

  doAssert not db.isNil

  result = TxPoolRef.init(db)
  if 0 < baseFee:
    result.setBaseFee(baseFee)
  result.setMaxRejects(itList.len)

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for item in itList:
      var tx = item.tx
      result.pjaAddTx(tx, item.info)
  result.pjaFlushRejects
  waitFor result.jobCommit
  doAssert result.count.total == itList.len
  doAssert result.count.disposed == 0


proc toTxPool*(
    db: BaseChainDB;
    itList: seq[TxItemRef];
    baseFee = 0.GasPrice;
    noisy = true): TxPoolRef =
  var newList = itList
  db.toTxPool(newList, baseFee, noisy)


proc toTxPool*(
    db: BaseChainDB;            ## to be modified, initialisier for `TxPool`
    timeGap: var Time;          ## to be set, time in the middle of time gap
    nGapItems: var int;         ## to be set, # items before time gap
    itList: var seq[TxItemRef]; ## import items into new `TxPool` (read only)
    baseFee = 0.GasPrice;       ## initalise with `baseFee` (unless 0)
    itemsPC = 30;               ## % number if items befor time gap
    delayMSecs = 200;           ## size of time vap
    noisy = true): TxPoolRef =
  ## Variant of `toTxPoolFromSeq()` with a time gap between consecutive
  ## items on the `remote` queue
  doAssert not db.isNil
  doAssert 0 < itemsPC and itemsPC < 100

  result = TxPoolRef.init(db)
  if 0 < baseFee:
    result.setBaseFee(baseFee)
  result.setMaxRejects(itList.len)

  let
    delayAt = itList.len * itemsPC div 100
    middleOfTimeGap = initDuration(milliSeconds = delayMSecs div 2)

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for n in 0 ..< itList.len:
      let item = itList[n]
      var tx = item.tx
      result.pjaAddTx(tx, item.info)
      if delayAt == n:
        nGapItems = n # pass back value
        noisy.say &"time gap after transactions"
        let itemID = item.itemID
        waitFor result.jobCommit
        doAssert result.count.disposed == 0
        timeGap = result.getItem(itemID).value.timeStamp + middleOfTimeGap
        delayMSecs.sleep

  waitFor result.jobCommit
  doAssert result.count.total == itList.len
  doAssert result.count.disposed == 0


proc toItems*(xp: TxPoolRef): seq[TxItemRef] =
  var rList: seq[TxItemRef]
  let itFn = proc(item: TxItemRef): bool =
               rList.add item
               true
  xp.pjaItemsApply(itFn)
  waitFor xp.jobCommit
  result = rList


proc setItemStatusFromInfo*(xp: TxPoolRef) =
  for item in xp.toItems:
    # Re-define status from last character of info field
    let w = TxItemStatus.toSeq.filterIt(statusInfo[it][0] == item.info[^1])[0]
    xp.setStatus(item, w)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

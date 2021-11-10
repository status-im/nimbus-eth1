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
  std/[algorithm, os, sequtils, strformat, tables, times],
  ../../nimbus/[config, chain_config, constants, genesis],
  ../../nimbus/db/[db_chain, accounts_cache],
  ../../nimbus/p2p/chain,
  ../../nimbus/utils/[ec_recover, tx_pool, tx_pool/tx_chain, tx_pool/tx_item],
  ./helpers,
  eth/[common, keys, p2p, trie/db],
  stew/[keyed_queue],
  stint

type
  AmendedAccountsRef* = ref object ##\
    ## Faked `getBalance()` and `getNonce()` account functions
    backAccounts: Table[EthAddress,(uint,uint64)] # (nonce,balance)
    back*: tuple[
      nonce: TxChainNonce,
      balance: TxChainBalance]
    forward*: tuple[
      nonce: TxChainNonce,
      balance: TxChainBalance]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc isOK(rc: ValidationResult): bool =
  rc == ValidationResult.OK

proc setStatus(xp: TxPoolRef; item: TxItemRef; status: TxItemStatus)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Change/update the status of the transaction item.
  if status != item.status:
    discard xp.txDB.reassign(item, status)

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
        if not chainDB.persistBlocks(headers,bodies).isOK:
          raiseAssert "persistBlocks() failed at block #" & $leadBlkNum
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
            result.chain.setBaseFee(baseFee)

          # Load transactions, one-by-one
          for n in 0 ..< txs.len:
            txCount.inc
            let
              status = getStatus()
              info = &"{txCount} #{blkNum}({chainNo}) "&
                     &"{n}/{txs.len} {statusInfo[status]}"
            noisy.showElapsed(&"insert: {info}"):
              result.jobAddTx(txs[n], info)
            if loadTxs <= txCount:
              break allDone

  result.jobCommit


proc toTxPool*(
    db: BaseChainDB;            ## to be modified, initialisier for `TxPool`
    itList: var seq[TxItemRef]; ## import items into new `TxPool` (read only)
    baseFee = 0.GasPrice;       ## initalise with `baseFee` (unless 0)
    noisy = true): TxPoolRef =

  doAssert not db.isNil

  result = TxPoolRef.init(db)
  result.chain.setBaseFee(baseFee)
  result.maxRejects = itList.len

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for item in itList:
      result.jobAddTx(item.tx, item.info)
  result.jobCommit
  doAssert result.nItems.total == itList.len


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
  result.chain.setBaseFee(baseFee)
  result.maxRejects = itList.len

  let
    delayAt = itList.len * itemsPC div 100
    middleOfTimeGap = initDuration(milliSeconds = delayMSecs div 2)

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for n in 0 ..< itList.len:
      let item = itList[n]
      result.jobAddTx(item.tx, item.info)
      if delayAt == n:
        nGapItems = n # pass back value
        noisy.say &"time gap after transactions"
        let itemID = item.itemID
        result.jobCommit
        doAssert result.nItems.disposed == 0
        timeGap = result.getItem(itemID).value.timeStamp + middleOfTimeGap
        delayMSecs.sleep

  result.jobCommit
  doAssert result.nItems.total == itList.len
  doAssert result.nItems.disposed == 0


proc toItems*(xp: TxPoolRef): seq[TxItemRef] =
  toSeq(xp.txDB.byItemID.nextValues)


proc setItemStatusFromInfo*(xp: TxPoolRef) =
  ## Re-define status from last character of info field. Note that this might
  ## violate boundary conditions regarding nonces.
  for item in xp.toItems:
    let w = TxItemStatus.toSeq.filterIt(statusInfo[it][0] == item.info[^1])[0]
    xp.setStatus(item, w)


proc getAmendedAccounts*(xp: TxPoolRef;
                         txs: seq[Transaction]): AmendedAccountsRef =
  ## Provide fake account state environment assuming the argument `txs`
  ## rolles back or forward the block chain states.
  let desc = AmendedAccountsRef()

  for tx in txs:
    var item: TxItemRef
    let rc = xp.getItem(tx.itemID)
    if rc.isOk:
      item = rc.value
    else:
      var ty = tx
      item = xp.recoverItem(ty).value
      if not xp.txDB.bySender.eq(item.sender).isErr:
        # no need to adjust unknown accounts
        continue
    if not desc.backAccounts.hasKey(item.sender):
      desc.backAccounts[item.sender] = (0u,0u64)
    let maxConsumed = item.tx.gasLimit.uint64 * item.tx.gasPrice.uint64
    desc.backAccounts[item.sender][0].inc
    desc.backAccounts[item.sender][1] += maxConsumed

  desc.back.nonce =
      proc(rdb: ReadOnlyStateDB; acc: EthAddress):AccountNonce =
        var nonce = rdb.getNonce(acc)
        if desc.backAccounts.hasKey(acc):
          if nonce < desc.backAccounts[acc][0]:
            return 0
          nonce -= desc.backAccounts[acc][0]
        return nonce

  desc.back.balance =
      proc(rdb: ReadOnlyStateDB; acc: EthAddress): UInt256 =
        var balance = rdb.getBalance(acc)
        if desc.backAccounts.hasKey(acc):
          if balance < desc.backAccounts[acc][1].u256:
            return 0.u256
          balance -= desc.backAccounts[acc][1].u256
        return balance

  desc.forward.nonce =
      proc(rdb: ReadOnlyStateDB; acc: EthAddress):AccountNonce =
        var nonce = rdb.getNonce(acc)
        if desc.backAccounts.hasKey(acc):
          nonce += desc.backAccounts[acc][0]
        return nonce

  desc.forward.balance =
      proc(rdb: ReadOnlyStateDB; acc: EthAddress): UInt256 =
        var balance = rdb.getBalance(acc)
        if desc.backAccounts.hasKey(acc):
          balance += desc.backAccounts[acc][1].u256
        return balance

  desc


proc getBackHeader*(xp: TxPoolRef; nTxs, nAccounts: int):
                  (BlockHeader, seq[Transaction], seq[EthAddress]) {.inline.} =
  ## back track the block chain for at least `nTxs` transactions and
  ## `nAccounts` sender accounts
  var
    accTab: Table[EthAddress,bool]
    txsLst: seq[Transaction]
    backHash = xp.head.blockHash
    backHeader = xp.head
    backBody = xp.chain.db.getBlockBody(backHash)

  while true:
    # count txs and step behind last block
    txsLst.add backBody.transactions
    backHash = backHeader.parentHash
    if not xp.chain.db.getBlockHeader(backHash, backHeader) or
       not xp.chain.db.getBlockBody(backHash, backBody):
      break

    # collect accounts unless max reached
    if accTab.len < nAccounts:
      for tx in backBody.transactions:
        let rc = tx.ecRecover
        if rc.isOK:
          if xp.txDB.bySender.eq(rc.value).isOk:
            accTab[rc.value] = true
            if nAccounts <= accTab.len:
              break

    if nTxs <= txsLst.len and nAccounts <= accTab.len:
      break
    # otherwise get next block

  (backHeader, txsLst.reversed, toSeq(accTab.keys))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

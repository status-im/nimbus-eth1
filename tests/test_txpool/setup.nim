# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[algorithm, os, sequtils, strformat, tables, times],
  ../../nimbus/core/[chain, tx_pool], # must be early (compilation annoyance)
  ../../nimbus/common/common,
  ../../nimbus/[config, constants],
  ../../nimbus/utils/ec_recover,
  ../../nimbus/core/tx_pool/[tx_chain, tx_item],
  ./helpers,
  ./sign_helper,
  eth/[keys, p2p],
  stew/[keyed_queue]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc setStatus(xp: TxPoolRef; item: TxItemRef; status: TxItemStatus)
    {.gcsafe,raises: [CatchableError].} =
  ## Change/update the status of the transaction item.
  if status != item.status:
    discard xp.txDB.reassign(item, status)

proc importBlocks(c: ChainRef; h: seq[BlockHeader]; b: seq[BlockBody]): int =
  if c.persistBlocks(h,b) != ValidationResult.OK:
    raiseAssert "persistBlocks() failed at block #" & $h[0].blockNumber
  for body in b:
    result += body.transactions.len

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blockChainForTesting*(network: NetworkID): CommonRef =

  result = CommonRef.new(
    newCoreDbRef LegacyDbMemory,
    networkId = network,
    params = network.networkParams)

  result.initializeEmptyDb

proc toTxPool*(
    com: CommonRef;                   ## to be modified
    file: string;                     ## input, file and transactions
    getStatus: proc(): TxItemStatus;  ## input, random function
    loadBlocks: int;                  ## load at most this many blocks
    minBlockTxs: int;                 ## load at least this many txs in blocks
    loadTxs: int;                     ## load at most this many transactions
    baseFee = 0.GasPrice;             ## initalise with `baseFee` (unless 0)
    noisy: bool): (TxPoolRef, int) =

  var
    txCount  = 0
    chainNo  = 0
    chainRef = com.newChain
    nTxs = 0

  doAssert not com.isNil
  result[0] = TxPoolRef.new(com,testAddress)
  result[0].baseFee = baseFee

  for chain in file.undumpBlocks:
    let leadBlkNum = chain[0][0].blockNumber
    chainNo.inc

    if loadTxs <= txCount:
      break

    # Verify Genesis
    if leadBlkNum == 0.u256:
      doAssert chain[0][0] == com.db.getBlockHeader(0.u256)
      continue

    if leadBlkNum < loadBlocks.u256 or nTxs < minBlockTxs:
      nTxs += chainRef.importBlocks(chain[0],chain[1])
      continue

    # Import transactions
    for inx in 0 ..< chain[0].len:
      let
        num = chain[0][inx].blockNumber
        txs = chain[1][inx].transactions

      # Continue importing up until first non-trivial block
      if txCount == 0 and txs.len == 0:
        nTxs += chainRef.importBlocks(@[chain[0][inx]],@[chain[1][inx]])
        continue

      # Load transactions, one-by-one
      for n in 0 ..< min(txs.len, loadTxs - txCount):
        txCount.inc
        let
          status = statusInfo[getStatus()]
          info = &"{txCount} #{num}({chainNo}) {n}/{txs.len} {status}"
        noisy.showElapsed(&"insert: {info}"):
          result[0].add(PooledTransaction(tx: txs[n]), info)

      if loadTxs <= txCount:
        break

  result[1] = nTxs


proc toTxPool*(
    com: CommonRef;               ## to be modified, initialisier for `TxPool`
    itList: seq[TxItemRef];       ## import items into new `TxPool` (read only)
    baseFee = 0.GasPrice;         ## initalise with `baseFee` (unless 0)
    local: seq[EthAddress] = @[]; ## local addresses
    noisy = true): TxPoolRef =

  doAssert not com.isNil

  result = TxPoolRef.new(com,testAddress)
  result.baseFee = baseFee
  result.maxRejects = itList.len

  let noLocals = local.len == 0
  var localAddr: Table[EthAddress,bool]
  for a in local:
    localAddr[a] = true

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for item in itList:
      if noLocals:
        result.add(item.pooledTx, item.info)
      elif localAddr.hasKey(item.sender):
        doAssert result.addLocal(item.pooledTx, true).isOk
      else:
        doAssert result.addRemote(item.pooledTx, true).isOk
  doAssert result.nItems.total == itList.len


proc toTxPool*(
    com: CommonRef;               ## to be modified, initialisier for `TxPool`
    timeGap: var Time;            ## to be set, time in the middle of time gap
    nGapItems: var int;           ## to be set, # items before time gap
    itList: var seq[TxItemRef];   ## import items into new `TxPool` (read only)
    baseFee = 0.GasPrice;         ## initalise with `baseFee` (unless 0)
    itemsPC = 30;                 ## % number if items befor time gap
    delayMSecs = 200;             ## size of time vap
    local: seq[EthAddress] = @[]; ## local addresses
    noisy = true): TxPoolRef =
  ## Variant of `toTxPoolFromSeq()` with a time gap between consecutive
  ## items on the `remote` queue
  doAssert not com.isNil
  doAssert 0 < itemsPC and itemsPC < 100

  result = TxPoolRef.new(com,testAddress)
  result.baseFee = baseFee
  result.maxRejects = itList.len

  let noLocals = local.len == 0
  var localAddr: Table[EthAddress,bool]
  for a in local:
    localAddr[a] = true

  let
    delayAt = itList.len * itemsPC div 100
    middleOfTimeGap = initDuration(milliSeconds = delayMSecs div 2)
  const
    tFmt = "yyyy-MM-dd'T'HH-mm-ss'.'fff"

  noisy.showElapsed(&"Loading {itList.len} transactions"):
    for n in 0 ..< itList.len:
      let item = itList[n]
      if noLocals:
        result.add(item.pooledTx, item.info)
      elif localAddr.hasKey(item.sender):
        doAssert result.addLocal(item.pooledTx, true).isOk
      else:
        doAssert result.addRemote(item.pooledTx, true).isOk
      if n < 3 or delayAt-3 <= n and n <= delayAt+3 or itList.len-4 < n:
        let t = result.getItem(item.itemID).value.timeStamp.format(tFmt, utc())
        noisy.say &"added item {n} time={t}"
      if delayAt == n:
        nGapItems = n # pass back value
        let itemID = item.itemID
        doAssert result.nItems.disposed == 0
        timeGap = result.getItem(itemID).value.timeStamp + middleOfTimeGap
        let t = timeGap.format(tFmt, utc())
        noisy.say &"{delayMSecs}ms time gap centered around {t}"
        delayMSecs.sleep

  doAssert result.nItems.total == itList.len
  doAssert result.nItems.disposed == 0


proc toItems*(xp: TxPoolRef): seq[TxItemRef] =
  toSeq(xp.txDB.byItemID.nextValues)

proc toItems*(xp: TxPoolRef; label: TxItemStatus): seq[TxItemRef] =
  for (_,nonceList) in xp.txDB.decAccount(label):
    result.add toSeq(nonceList.incNonce)

proc setItemStatusFromInfo*(xp: TxPoolRef) =
  ## Re-define status from last character of info field. Note that this might
  ## violate boundary conditions regarding nonces.
  for item in xp.toItems:
    let w = TxItemStatus.toSeq.filterIt(statusInfo[it][0] == item.info[^1])[0]
    xp.setStatus(item, w)


proc getBackHeader*(xp: TxPoolRef; nTxs, nAccounts: int):
                  (BlockHeader, seq[Transaction], seq[EthAddress]) {.inline.} =
  ## back track the block chain for at least `nTxs` transactions and
  ## `nAccounts` sender accounts
  var
    accTab: Table[EthAddress,bool]
    txsLst: seq[Transaction]
    backHash = xp.head.blockHash
    backHeader = xp.head
    backBody = xp.chain.com.db.getBlockBody(backHash)

  while true:
    # count txs and step behind last block
    txsLst.add backBody.transactions
    backHash = backHeader.parentHash
    if not xp.chain.com.db.getBlockHeader(backHash, backHeader) or
       not xp.chain.com.db.getBlockBody(backHash, backBody):
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

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
  std/[algorithm, os, sequtils, strformat, tables, times, json],
  ../../nimbus/core/[chain, tx_pool], # must be early (compilation annoyance)
  ../../nimbus/common/common,
  ../../nimbus/[config, constants],
  ../../nimbus/utils/ec_recover,
  ../../nimbus/core/tx_pool/[tx_chain, tx_item],
  ../../nimbus/transaction,
  ./helpers,
  eth/[keys, p2p],
  stew/[keyed_queue, byteutils]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc setStatus(xp: TxPoolRef; item: TxItemRef; status: TxItemStatus)
    {.gcsafe,raises: [CatchableError].} =
  ## Change/update the status of the transaction item.
  if status != item.status:
    discard xp.txDB.reassign(item, status)

type
  TxEnv = object
    chainId: ChainID
    rng: ref HmacDrbgContext
    signers: Table[EthAddress, PrivateKey]
    map: Table[EthAddress, EthAddress]
    txs: seq[Transaction]

  Signer = object
    address: EthAddress
    signer: PrivateKey

const
  genesisFile = "tests/customgenesis/cancun123.json"

proc initTxEnv(chainId: ChainID): TxEnv =
  result.rng = newRng()
  result.chainId = chainId

proc getSigner(env: var TxEnv, address: EthAddress): Signer =
  env.map.withValue(address, val) do:
    let newAddress = val[]
    return Signer(address: newAddress, signer: env.signers[newAddress])
  do:
    let key = PrivateKey.random(env.rng[])
    let newAddress = toCanonicalAddress(key.toPublicKey)
    env.map[address] = newAddress
    env.signers[newAddress] = key
    return Signer(address: newAddress, signer: key)

proc fillGenesis(env: var TxEnv, param: NetworkParams) =
  const txFile = "tests/test_txpool/transactions.json"
  let n = json.parseFile(txFile)

  var map: Table[EthAddress, UInt256]

  for z in n:
    let bytes = hexToSeqByte(z.getStr)
    let tx = rlp.decode(bytes, Transaction)
    let sender = tx.getSender()
    let bal = map.getOrDefault(sender, 0.u256)
    if bal + tx.value > 0:
      map[sender] = bal + tx.value
    env.txs.add(tx)

  for k, v in map:
    let s = env.getSigner(k)
    param.genesis.alloc[s.address] = GenesisAccount(
      balance: v + v,
    )

proc setupTxPool*(getStatus: proc(): TxItemStatus): (CommonRef, TxPoolRef, int) =
  let
    conf = makeConfig(@[
      "--custom-network:" & genesisFile
    ])

  var txEnv = initTxEnv(conf.networkParams.config.chainId)
  txEnv.fillGenesis(conf.networkParams)

  let com = CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    conf.networkId,
    conf.networkParams
  )

  com.initializeEmptyDb()
  let txPool = TxPoolRef.new(com)

  for n, tx in txEnv.txs:
    let s = txEnv.getSigner(tx.getSender())
    let status = statusInfo[getStatus()]
    let info = &"{n}/{txEnv.txs.len} {status}"
    let signedTx = signTransaction(tx, s.signer, txEnv.chainId, eip155 = true)
    txPool.add(PooledTransaction(tx: signedTx), info)

  (com, txPool, txEnv.txs.len)

proc toTxPool*(
    com: CommonRef;               ## to be modified, initialisier for `TxPool`
    itList: seq[TxItemRef];       ## import items into new `TxPool` (read only)
    baseFee = 0.GasPrice;         ## initalise with `baseFee` (unless 0)
    local: seq[EthAddress] = @[]; ## local addresses
    noisy = true): TxPoolRef =

  doAssert not com.isNil

  result = TxPoolRef.new(com)
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

  result = TxPoolRef.new(com)
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
    let w = TxItemStatus.toSeq.filterIt(statusInfo[it][0] == item.info[^1])
    if w.len > 0:
      xp.setStatus(item, w[0])


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

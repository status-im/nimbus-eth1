# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  eth/common/eth_types,
  eth/common/eth_types_rlp,
  web3/eth_api_types,
  ../beacon/web3_eth_conv,
  ../constants,
  ../transaction

proc toWd(wd: eth_types.Withdrawal): WithdrawalObject =
  WithdrawalObject(
    index: w3Qty wd.index,
    validatorIndex: w3Qty wd.validatorIndex,
    address: w3Addr wd.address,
    amount: w3Qty wd.amount,
  )

proc toWdList(list: openArray[eth_types.Withdrawal]): seq[WithdrawalObject] =
  result = newSeqOfCap[WithdrawalObject](list.len)
  for x in list:
    result.add toWd(x)

func toWdList(x: Opt[seq[eth_types.Withdrawal]]):
                     Opt[seq[WithdrawalObject]] =
  if x.isNone: Opt.none(seq[WithdrawalObject])
  else: Opt.some(toWdList x.get)

proc populateTransactionObject*(tx: Transaction,
                                optionalHash: Opt[eth_types.Hash256] = Opt.none(eth_types.Hash256),
                                optionalNumber: Opt[eth_types.BlockNumber] = Opt.none(eth_types.BlockNumber),
                                txIndex: Opt[uint64] = Opt.none(uint64)): TransactionObject =
  result = TransactionObject()
  result.`type` = Opt.some Quantity(tx.txType)
  result.blockHash = w3Hash optionalHash
  result.blockNumber = w3BlockNumber optionalNumber

  var sender: EthAddress
  if tx.getSender(sender):
    result.`from` = w3Addr sender
  result.gas = w3Qty(tx.gasLimit)
  result.gasPrice = w3Qty(tx.gasPrice)
  result.hash = w3Hash tx.rlpHash
  result.input = tx.payload
  result.nonce = w3Qty(tx.nonce)
  result.to = Opt.some(w3Addr tx.destination)
  if txIndex.isSome:
    result.transactionIndex = Opt.some(Quantity(txIndex.get))
  result.value = tx.value
  result.v = w3Qty(tx.V)
  result.r = tx.R
  result.s = tx.S
  result.maxFeePerGas = Opt.some w3Qty(tx.maxFeePerGas)
  result.maxPriorityFeePerGas = Opt.some w3Qty(tx.maxPriorityFeePerGas)

  if tx.txType >= TxEip2930:
    result.chainId = Opt.some(Web3Quantity(tx.chainId))
    result.accessList = Opt.some(w3AccessList(tx.accessList))

  if tx.txType >= TxEIP4844:
    result.maxFeePerBlobGas = Opt.some(tx.maxFeePerBlobGas)
    result.blobVersionedHashes = Opt.some(w3Hashes tx.versionedHashes)

proc populateBlockObject*(blockHash: eth_types.Hash256,
                          blk: EthBlock,
                          fullTx: bool): BlockObject =
  template header: auto = blk.header

  result = BlockObject()
  result.number = w3BlockNumber(header.number)
  result.hash = w3Hash blockHash
  result.parentHash = w3Hash header.parentHash
  result.nonce = Opt.some(FixedBytes[8] header.nonce)
  result.sha3Uncles = w3Hash header.ommersHash
  result.logsBloom = FixedBytes[256] header.logsBloom
  result.transactionsRoot = w3Hash header.txRoot
  result.stateRoot = w3Hash header.stateRoot
  result.receiptsRoot = w3Hash header.receiptsRoot
  result.miner = w3Addr header.coinbase
  result.difficulty = header.difficulty
  result.extraData = HistoricExtraData header.extraData
  result.mixHash = w3Hash header.mixHash

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(eth_types.BlockHeader) - sizeof(eth_types.Blob) + header.extraData.len
  result.size = Quantity(size)

  result.gasLimit  = w3Qty(header.gasLimit)
  result.gasUsed   = w3Qty(header.gasUsed)
  result.timestamp = w3Qty(header.timestamp)
  result.baseFeePerGas = header.baseFeePerGas

  if fullTx:
    for i, tx in blk.transactions:
      let txObj = populateTransactionObject(tx,
        Opt.some(blockHash),
        Opt.some(header.number), Opt.some(i.uint64))
      result.transactions.add txOrHash(txObj)
  else:
    for i, tx in blk.transactions:
      let txHash = rlpHash(tx)
      result.transactions.add txOrHash(w3Hash(txHash))

  result.withdrawalsRoot = w3Hash header.withdrawalsRoot
  result.withdrawals = toWdList blk.withdrawals
  result.parentBeaconBlockRoot = w3Hash header.parentBeaconBlockRoot
  result.blobGasUsed = w3Qty(header.blobGasUsed)
  result.excessBlobGas = w3Qty(header.excessBlobGas)

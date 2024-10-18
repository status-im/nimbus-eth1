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
  eth/common/[eth_types, eth_types_rlp, transaction_utils],
  web3/eth_api_types,
  ../constants,
  ../transaction

from ../beacon/web3_eth_conv import w3Qty

proc toWd(wd: eth_types.Withdrawal): WithdrawalObject =
  WithdrawalObject(
    index: Quantity(wd.index),
    validatorIndex: Quantity wd.validatorIndex,
    address: wd.address,
    amount: Quantity wd.amount,
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
                                optionalHash: Opt[eth_types.Hash32] = Opt.none(eth_types.Hash32),
                                optionalNumber: Opt[eth_types.BlockNumber] = Opt.none(eth_types.BlockNumber),
                                txIndex: Opt[uint64] = Opt.none(uint64)): TransactionObject =
  result = TransactionObject()
  result.`type` = Opt.some Quantity(tx.txType)
  result.blockHash = optionalHash
  result.blockNumber = w3Qty(optionalNumber)

  if (let sender = tx.recoverSender(); sender.isOk):
    result.`from` = sender[]
  result.gas = Quantity(tx.gasLimit)
  result.gasPrice = Quantity(tx.gasPrice)
  result.hash = tx.rlpHash
  result.input = tx.payload
  result.nonce = Quantity(tx.nonce)
  result.to = Opt.some(tx.destination)
  if txIndex.isSome:
    result.transactionIndex = Opt.some(Quantity(txIndex.get))
  result.value = tx.value
  result.v = Quantity(tx.V)
  result.r = tx.R
  result.s = tx.S
  result.maxFeePerGas = Opt.some Quantity(tx.maxFeePerGas)
  result.maxPriorityFeePerGas = Opt.some Quantity(tx.maxPriorityFeePerGas)

  if tx.txType >= TxEip2930:
    result.chainId = Opt.some(Quantity(tx.chainId))
    result.accessList = Opt.some(tx.accessList)

  if tx.txType >= TxEIP4844:
    result.maxFeePerBlobGas = Opt.some(tx.maxFeePerBlobGas)
    result.blobVersionedHashes = Opt.some(tx.versionedHashes)

proc populateBlockObject*(blockHash: eth_types.Hash32,
                          blk: Block,
                          fullTx: bool): BlockObject =
  template header: auto = blk.header

  result = BlockObject()
  result.number = Quantity(header.number)
  result.hash = blockHash
  result.parentHash = header.parentHash
  result.nonce = Opt.some(header.nonce)
  result.sha3Uncles = header.ommersHash
  result.logsBloom = header.logsBloom
  result.transactionsRoot = header.txRoot
  result.stateRoot = header.stateRoot
  result.receiptsRoot = header.receiptsRoot
  result.miner = header.coinbase
  result.difficulty = header.difficulty
  result.extraData = HistoricExtraData header.extraData
  result.mixHash = Hash32 header.mixHash

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(eth_types.Header) - sizeof(eth_api_types.Blob) + header.extraData.len
  result.size = Quantity(size)

  result.gasLimit  = Quantity(header.gasLimit)
  result.gasUsed   = Quantity(header.gasUsed)
  result.timestamp = Quantity(header.timestamp)
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
      result.transactions.add txOrHash(txHash)

  result.withdrawalsRoot = header.withdrawalsRoot
  result.withdrawals = toWdList blk.withdrawals
  result.parentBeaconBlockRoot = header.parentBeaconBlockRoot
  result.blobGasUsed = w3Qty(header.blobGasUsed)
  result.excessBlobGas = w3Qty(header.excessBlobGas)

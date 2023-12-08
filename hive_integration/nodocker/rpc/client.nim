# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/strutils,
  eth/[common, keys, rlp],
  stew/byteutils,
  chronos, stint,
  json_rpc/[rpcclient],
  ../../../nimbus/transaction,
  ../../../nimbus/utils/utils,
  ../../../nimbus/beacon/web3_eth_conv,
  web3/eth_api

export eth_api

proc sendTransaction*(client: RpcClient, tx: Transaction): Future[bool] {.async.} =
  let data   = rlp.encode(tx)
  let txHash = keccakHash(data)
  let hex    = await client.eth_sendRawTransaction(data)
  let decodedHash = ethHash(hex)
  result = decodedHash == txHash

proc blockNumber*(client: RpcClient): Future[uint64] {.async.} =
  let hex = await client.eth_blockNumber()
  result = hex.uint64

proc balanceAt*(client: RpcClient, address: EthAddress, number: uint64): Future[UInt256] {.async.} =
  let hex = await client.eth_getBalance(w3Addr(address), blockId(number))
  result = hex

proc balanceAt*(client: RpcClient, address: EthAddress): Future[UInt256] {.async.} =
  let hex = await client.eth_getBalance(w3Addr(address), blockId("latest"))
  result = hex

proc nonceAt*(client: RpcClient, address: EthAddress): Future[AccountNonce] {.async.} =
  let hex = await client.eth_getTransactionCount(w3Addr(address), blockId("latest"))
  result = hex.AccountNonce

func toTopics(list: openArray[Web3Hash]): seq[common.Topic] =
  result = newSeqOfCap[common.Topic](list.len)
  for x in list:
    result.add common.Topic(x)

func toLogs(list: openArray[LogObject]): seq[Log] =
  result = newSeqOfCap[Log](list.len)
  for x in list:
    result.add Log(
      address: ethAddr x.address,
      data: x.data,
      topics: toTopics(x.topics)
    )

proc txReceipt*(client: RpcClient, txHash: common.Hash256): Future[Option[Receipt]] {.async.} =
  let rc = await client.eth_getTransactionReceipt(w3Hash txHash)
  if rc.isNil:
    return none(Receipt)

  let rec = Receipt(
    receiptType: LegacyReceipt,
    isHash     : rc.root.isSome,
    status     : rc.status.isSome,
    hash       : ethHash rc.root.get(w3Hash()),
    cumulativeGasUsed: rc.cumulativeGasUsed.GasInt,
    bloom      : BloomFilter(rc.logsBloom),
    logs       : toLogs(rc.logs)
  )
  result = some(rec)

proc gasUsed*(client: RpcClient, txHash: common.Hash256): Future[Option[GasInt]] {.async.} =
  let rc = await client.eth_getTransactionReceipt(w3Hash txHash)
  if rc.isNil:
    return none(GasInt)

  result = some(rc.gasUsed.GasInt)

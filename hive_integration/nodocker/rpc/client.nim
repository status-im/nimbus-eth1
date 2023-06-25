# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
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
  ../../../nimbus/rpc/hexstrings,
  ../../../tests/rpcclient/eth_api

export eth_api

proc fromHex(x: type Hash256, hex: EthHashStr): Hash256 =
  hexToByteArray(hex.string, result.data)

proc sendTransaction*(client: RpcClient, tx: Transaction): Future[bool] {.async.} =
  let data   = rlp.encode(tx)
  let txHash = keccakHash(data)
  let hex    = await client.eth_sendRawTransaction(hexDataStr(data))
  let decodedHash = Hash256.fromHex(hex)
  result = decodedHash == txHash

proc blockNumber*(client: RpcClient): Future[uint64] {.async.} =
  let hex = await client.eth_blockNumber()
  result = parseHexInt(hex.string).uint64

proc balanceAt*(client: RpcClient, address: EthAddress, blockNumber: uint64): Future[UInt256] {.async.} =
  let hex = await client.eth_getBalance(ethAddressStr(address), encodeQuantity(blockNumber).string)
  result = UInt256.fromHex(hex.string)

proc balanceAt*(client: RpcClient, address: EthAddress): Future[UInt256] {.async.} =
  let hex = await client.eth_getBalance(ethAddressStr(address), "latest")
  result = UInt256.fromHex(hex.string)

proc nonceAt*(client: RpcClient, address: EthAddress): Future[AccountNonce] {.async.} =
  let hex = await client.eth_getTransactionCount(ethAddressStr(address), "latest")
  result = parseHexInt(hex.string).AccountNonce

func toTopics(list: openArray[Hash256]): seq[Topic] =
  result = newSeqOfCap[Topic](list.len)
  for x in list:
    result.add x.data
  
func toLogs(list: openArray[FilterLog]): seq[Log] =
  result = newSeqOfCap[Log](list.len)
  for x in list:
    result.add Log(
      address: x.address,
      data: x.data,
      topics: toTopics(x.topics)
    )

proc txReceipt*(client: RpcClient, txHash: Hash256): Future[Option[Receipt]] {.async.} =
  let rr = await client.eth_getTransactionReceipt(txHash)
  if rr.isNone:
    return none(Receipt)

  let rc = rr.get()
  let rec = Receipt(
    receiptType: LegacyReceipt,
    isHash     : rc.root.isSome,
    status     : rc.status.isSome,
    hash       : rc.root.get(Hash256()),
    cumulativeGasUsed: parseHexInt(rc.cumulativeGasUsed.string).GasInt,
    bloom      : BloomFilter(rc.logsBloom),
    logs       : toLogs(rc.logs)
  )
  result = some(rec)

proc gasUsed*(client: RpcClient, txHash: Hash256): Future[Option[GasInt]] {.async.} =
  let rr = await client.eth_getTransactionReceipt(txHash)
  if rr.isNone:
    return none(GasInt)

  let rc = rr.get()
  result = some(parseHexInt(rc.gasUsed.string).GasInt)

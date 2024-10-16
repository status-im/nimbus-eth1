# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common/[eth_types_rlp],
  eth/rlp,
  chronos, stint,
  json_rpc/[rpcclient],
  ../../../nimbus/transaction,
  ../../../nimbus/utils/utils,
  ../../../nimbus/beacon/web3_eth_conv,
  web3/eth_api

export eth_api

proc sendTransaction*(
    client: RpcClient, tx: PooledTransaction): Future[bool] {.async.} =
  let data   = rlp.encode(tx)
  let txHash = keccak256(data)
  let hex    = await client.eth_sendRawTransaction(data)
  let decodedHash = hex
  result = decodedHash == txHash

proc blockNumber*(client: RpcClient): Future[uint64] {.async.} =
  let hex = await client.eth_blockNumber()
  result = hex.uint64

proc balanceAt*(client: RpcClient, address: Address, number: uint64): Future[UInt256] {.async.} =
  let hex = await client.eth_getBalance(address, blockId(number))
  result = hex

proc balanceAt*(client: RpcClient, address: Address): Future[UInt256] {.async.} =
  let hex = await client.eth_getBalance(address, blockId("latest"))
  result = hex

proc nonceAt*(client: RpcClient, address: Address): Future[AccountNonce] {.async.} =
  let hex = await client.eth_getTransactionCount(address, blockId("latest"))
  result = hex.AccountNonce

func toTopics(list: openArray[Hash32]): seq[eth_types.Topic] =
  result = newSeqOfCap[eth_types.Topic](list.len)
  for x in list:
    result.add eth_types.Topic(x)

func toLogs(list: openArray[LogObject]): seq[Log] =
  result = newSeqOfCap[Log](list.len)
  for x in list:
    result.add Log(
      address: x.address,
      data: x.data,
      topics: x.topics
    )

proc txReceipt*(client: RpcClient, txHash: eth_types.Hash32): Future[Option[Receipt]] {.async.} =
  let rc = await client.eth_getTransactionReceipt(txHash)
  if rc.isNil:
    return none(Receipt)

  let rec = Receipt(
    receiptType: LegacyReceipt,
    isHash     : rc.root.isSome,
    status     : rc.status.isSome,
    hash       : rc.root.get(default(Hash32)),
    cumulativeGasUsed: rc.cumulativeGasUsed.GasInt,
    logsBloom  : rc.logsBloom,
    logs       : toLogs(rc.logs)
  )
  result = some(rec)

proc gasUsed*(client: RpcClient, txHash: eth_types.Hash32): Future[Option[GasInt]] {.async.} =
  let rc = await client.eth_getTransactionReceipt(txHash)
  if rc.isNil:
    return none(GasInt)

  result = some(rc.gasUsed.GasInt)

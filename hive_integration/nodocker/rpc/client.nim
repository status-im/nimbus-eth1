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
  ../../../nimbus/[utils, transaction],
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

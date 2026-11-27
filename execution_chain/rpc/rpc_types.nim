# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common/block_access_lists,
  web3/[eth_api_types, conversions],
  ../beacon/web3_eth_conv

export eth_api_types, web3_eth_conv

type
  FilterLog* = eth_api_types.LogObject

  # BlockTag instead of BlockId:
  # prevent type clash with eth2 BlockId in portal/verified_proxy
  BlockTag* = eth_api_types.RtBlockIdentifier

  # eth_getProof echoes each requested key in one of two encodings, which
  # the web3 StorageProof with its UInt256 key cannot keep.
  RpcStorageProof* = object
    key*: string
    value*: UInt256
    proof*: seq[RlpEncodedBytes]

  RpcProofResponse* = object
    address*: Address
    accountProof*: seq[RlpEncodedBytes]
    balance*: UInt256
    codeHash*: Hash32
    nonce*: Quantity
    storageHash*: Hash32
    storageProof*: seq[RpcStorageProof]


proc writeValue*(
    w: var JsonWriter[EthJson], val: BlockAccessIndex
) {.raises: [IOError].} =
  w.writeValue(val.uint64)

proc readValue*(
    r: var JsonReader[EthJson], val: var BlockAccessIndex
) {.raises: [SerializationError, IOError].} =
  val = BlockAccessIndex(r.readValue(uint64))

# Block access list json serialization
AccountChanges.useDefaultSerializationIn EthJson
SlotChanges.useDefaultSerializationIn EthJson
StorageChange.useDefaultSerializationIn EthJson
BalanceChange.useDefaultSerializationIn EthJson
NonceChange.useDefaultSerializationIn EthJson
CodeChange.useDefaultSerializationIn EthJson

RpcStorageProof.useDefaultSerializationIn EthJson
RpcProofResponse.useDefaultSerializationIn EthJson

# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/strutils,
  stew/byteutils,
  eth/common/block_access_lists,
  web3/[eth_api_types, conversions],
  ../beacon/web3_eth_conv

export eth_api_types, web3_eth_conv

type
  FilterLog* = eth_api_types.LogObject

  # BlockTag instead of BlockId:
  # prevent type clash with eth2 BlockId in portal/verified_proxy
  BlockTag* = eth_api_types.RtBlockIdentifier

  BlockNumberOrTagOrHashKind* = enum
    number
    tag
    hash

  BlockNumberOrTagOrHash* = object
    case kind*: BlockNumberOrTagOrHashKind
    of number:
      number*: Quantity
    of tag:
      tag*: string
    of hash:
      hash*: Hash32

# Block access list json serialization
AccountChanges.useDefaultSerializationIn JrpcConv
SlotChanges.useDefaultSerializationIn JrpcConv
StorageChange.useDefaultSerializationIn JrpcConv
BalanceChange.useDefaultSerializationIn JrpcConv
NonceChange.useDefaultSerializationIn JrpcConv
CodeChange.useDefaultSerializationIn JrpcConv

func valid(hex: string): bool =
  var start = 0
  if hex.len >= 2:
    if hex[0] == '0' and hex[1] in {'x', 'X'}:
      start = 2
    else:
      return false
  else:
    return false

  for i in start ..< hex.len:
    let x = hex[i]
    if x notin HexDigits:
      return false
  true

template wrapValueError(body: untyped) =
  try:
    body
  except ValueError as exc:
    r.raiseUnexpectedValue(exc.msg)

proc readValue*(
    r: var JsonReader[JrpcConv], val: var BlockNumberOrTagOrHash
) {.gcsafe, raises: [IOError, JsonReaderError].} =
  let value = r.parseString()

  wrapValueError:
    if valid(value):
      if value.len() >= 64:
        val = BlockNumberOrTagOrHash(kind: hash, hash: fromHex(Hash32, value))
      else:
        val = BlockNumberOrTagOrHash(kind: number, number: Quantity fromHex[uint64](value))
    else:
      val = BlockNumberOrTagOrHash(kind: tag, tag: value)

proc writeValue*(
    w: var JsonWriter[JrpcConv], v: BlockNumberOrTagOrHash
) {.gcsafe, raises: [IOError].} =
  case v.kind
  of number:
    w.writeValue(v.number)
  of tag:
    w.writeValue(v.tag)
  of hash:
    w.writeValue(v.hash)

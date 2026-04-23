# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[strutils],
  stint,
  stew/byteutils,
  json_rpc/[jsonmarshal],
  web3/[conversions, eth_api_types],
  beacon_chain/spec/eth2_apis/eth2_rest_json_serialization

# taken from nim-json-rpc and adapted
func unpackArg*(
    arg: string, argType: type Address
): Result[Address, string] {.raises: [].} =
  try:
    ok(Address.fromHex(arg))
  except ValueError as e:
    err("Parameter of type " & $argType & " coudln't be decoded: " & e.msg)

func unpackArg*(
    arg: string, argType: type BlockTag
): Result[BlockTag, string] {.raises: [].} =
  try:
    ok(BlockTag(kind: bidNumber, number: Quantity(fromHex[uint64](arg))))
  except ValueError:
    ok(BlockTag(kind: bidAlias, alias: arg))

func unpackArg*(
    arg: string, argType: type UInt256
): Result[UInt256, string] {.raises: [].} =
  try:
    ok(UInt256.fromHex(arg))
  except ValueError as e:
    err("Parameter of type " & $argType & " coudldn't be decoded: " & e.msg)

func unpackArg*(
    arg: string, argType: type Hash32
): Result[Hash32, string] {.raises: [].} =
  try:
    ok(Hash32.fromHex(arg))
  except ValueError as e:
    err("Parameter of type " & $argType & " coudldn't be decoded: " & e.msg)

func unpackArg*(arg: string, argType: type): Result[argType, string] {.raises: [].} =
  try:
    ok(JrpcConv.decode(arg, argType))
  except CatchableError as e:
    err("Parameter of type " & $argType & " coudln't be decoded: " & e.msg)

func packArg*[T](arg: T): Result[string, string] {.raises: [].} =
  try:
    ok(JrpcConv.encode(arg))
  except CatchableError as e:
    err("Parameter coudln't be encoded: " & e.msg)

proc alloc*(str: string): cstring =
  var ret = cast[cstring](allocShared(str.len + 1))
  doAssert(ret != nil)
  copyMem(ret, str.cstring, str.len)
  ret[str.len] = '\0'
  return ret

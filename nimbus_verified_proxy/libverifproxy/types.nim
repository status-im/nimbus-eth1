# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strutils, lists],
  stint,
  stew/byteutils,
  ../engine/types,
  chronos,
  json_rpc/[jsonmarshal],
  web3/[eth_api_types, conversions]

type
  Task* = ref object
    status*: cint
    userData*: pointer
    response*: string
    finished*: bool
    cb*: CallBackProc
    fut*: FutureBase

  Context* = object
    config*: string
    tasks*: SinglyLinkedList[Task]
    taskLen*: int
    stop*: bool
    frontend*: EthApiFrontend

  CallBackProc* = proc(ctx: ptr Context, status: cint, res: cstring, userData: pointer) {.
    cdecl, gcsafe, raises: []
  .}

  TransportProc* = proc(
    ctx: ptr Context,
    name: cstring,
    params: cstring,
    cb: CallBackProc,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  CallBackData*[T] = object
    fut*: Future[EngineResult[T]]

const RET_SUCCESS*: cint = 0 # when the call to eth api frontend is successful
const RET_ERROR*: cint = -1 # when the call to eth api frontend failed with an error
const RET_CANCELLED*: cint = -2 # when the call to the eth api frontend was cancelled
# when an error occured while deserializing arguments from C to Nim
const RET_DESER_ERROR*: cint = -3

proc createCbData*[T](fut: Future[EngineResult[T]]): pointer =
  let data = CallBackData[T].new()
  data.fut = fut

  cast[pointer](data)

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
    # if it is an invalid alias it verification engine will throw an error
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

# generalized overloading
func unpackArg*(arg: string, argType: type): Result[argType, string] {.raises: [].} =
  try:
    ok(JrpcConv.decode(arg, argType))
  except CatchableError as e:
    err("Parameter of type " & $argType & " coudln't be decoded: " & e.msg)

# generalized overloading
func packArg*[T](arg: T): Result[string, string] {.raises: [].} =
  try:
    ok(JrpcConv.encode(arg))
  except CatchableError as e:
    err("Parameter coudln't be encoded: " & e.msg)

proc alloc*(str: string): cstring =
  var ret = cast[cstring](allocShared(str.len + 1))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret

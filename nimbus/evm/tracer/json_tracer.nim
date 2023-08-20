# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, sets, streams, strutils],
  eth/common/eth_types,
  eth/rlp,
  stew/byteutils,
  chronicles,
  ".."/[types, memory, stack],
  ../interpreter/op_codes,
  ../../db/accounts_cache,
  ../../errors

type
  JsonTracer* = ref object of TracerRef
    stream: Stream
    pretty: bool
    comp: Computation
    gas: GasInt
    pc: int
    stack: JsonNode
    storageKeys: seq[HashSet[UInt256]]
    index: int

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeHexInt(x: SomeInteger): JsonNode =
  %("0x" & x.toHex.stripLeadingZeros.toLowerAscii)

proc `%`(x: openArray[byte]): JsonNode =
  %("0x" & x.toHex)

proc writeJson(ctx: JsonTracer, res: JsonNode) =
  try:
    if ctx.pretty:
      ctx.stream.writeLine(res.pretty)
    else:
      ctx.stream.writeLine($res)
  except IOError as ex:
    error "JsonTracer writeJson", msg=ex.msg
  except OSError as ex:
    error "JsonTracer writeJson", msg=ex.msg

proc rememberStorageKey(ctx: JsonTracer, compDepth: int, key: UInt256) =
  ctx.storageKeys[compDepth].incl key

iterator storage(ctx: JsonTracer, compDepth: int): UInt256 =
  doAssert compDepth >= 0 and compDepth < ctx.storageKeys.len
  for key in ctx.storageKeys[compDepth]:
    yield key

proc captureOpImpl(ctx: JsonTracer, pc: int,
                   op: Op, gas: GasInt, refund: GasInt,
                   rData: openArray[byte],
                   depth: int, error: Option[string]) {.gcsafe.} =
  let
    gasCost = ctx.gas - gas
    c = ctx.comp

  var res = %{
    "pc": %(ctx.pc),
    "op": %(op.int),
    "gas": encodeHexInt(ctx.gas),
    "gasCost": encodeHexInt(gasCost),
    "memSize": %(c.memory.len)
  }

  if TracerFlags.DisableMemory notin ctx.flags:
    let mem = newJArray()
    const chunkLen = 32
    let numChunks = c.memory.len div chunkLen
    for i in 0 ..< numChunks:
      let memHex = c.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex()
      mem.add(%("0x" & memHex.toLowerAscii))
    res["memory"] = mem

  if TracerFlags.DisableStack notin ctx.flags:
    if ctx.stack.isNil:
      res["stack"] = newJArray()
    else:
      res["stack"] = ctx.stack

  if TracerFlags.DisableReturnData notin ctx.flags:
    res["returnData"] = %(rData)

  if TracerFlags.DisableStorage notin ctx.flags:
    var storage = newJObject()
    if c.msg.depth < ctx.storageKeys.len:
      var stateDB = c.vmState.stateDB
      for key in ctx.storage(c.msg.depth):
        let value = stateDB.getStorage(c.msg.contractAddress, key)
        storage["0x" & key.dumpHex.stripLeadingZeros] =
            %("0x" & value.dumpHex.stripLeadingZeros)
    res["storage"] = storage

  res["depth"] = %(depth)
  res["refund"] = %(refund)
  res["opName"] = %(($op).toUpperAscii)

  if error.isSome:
    res["error"] = %(error.get)

  ctx.writeJson(res)

proc newJsonTracer*(stream: Stream, flags: set[TracerFlags], pretty: bool): JsonTracer =
  JsonTracer(
    flags: flags,
    stream: stream,
    pretty: pretty
  )

method capturePrepare*(ctx: JsonTracer, depth: int) {.gcsafe.} =
  if depth >= ctx.storageKeys.len:
    let prevLen = ctx.storageKeys.len
    ctx.storageKeys.setLen(depth + 1)
    for i in prevLen ..< ctx.storageKeys.len - 1:
      ctx.storageKeys[i] = initHashSet[UInt256]()

  ctx.storageKeys[depth] = initHashSet[UInt256]()

# Top call frame
method captureStart*(ctx: JsonTracer, c: Computation,
                     sender: EthAddress, to: EthAddress,
                     create: bool, input: openArray[byte],
                     gas: GasInt, value: UInt256) {.gcsafe.} =
  ctx.comp = c

method captureEnd*(ctx: JsonTracer, output: openArray[byte],
                   gasUsed: GasInt, error: Option[string]) {.gcsafe.} =
  var res = %{
    "output": %(output),
    "gasUsed": encodeHexInt(gasUsed)
  }
  if error.isSome:
    res["error"] = %(error.get())
  ctx.writeJson(res)

# Opcode level
method captureOpStart*(ctx: JsonTracer, pc: int,
                       op: Op, gas: GasInt,
                       depth: int): int {.gcsafe.} =
  ctx.gas = gas
  ctx.pc = pc

  if TracerFlags.DisableStack notin ctx.flags:
    let c = ctx.comp
    ctx.stack = newJArray()
    for v in c.stack.values:
      ctx.stack.add(%("0x" & v.dumpHex.stripLeadingZeros))

  if TracerFlags.DisableStorage notin ctx.flags and op == SSTORE:
    try:
      let c = ctx.comp
      if c.stack.values.len > 1:
        ctx.rememberStorageKey(c.msg.depth, c.stack[^1, UInt256])
    except InsufficientStack as ex:
      error "JsonTracer captureOpStart", msg=ex.msg
    except ValueError as ex:
      error "JsonTracer captureOpStart", msg=ex.msg

  result = ctx.index
  inc ctx.index

method captureOpEnd*(ctx: JsonTracer, pc: int,
                     op: Op, gas: GasInt, refund: GasInt,
                     rData: openArray[byte],
                     depth: int, opIndex: int) {.gcsafe.} =
  try:
    ctx.captureOpImpl(pc, op, gas, refund, rData, depth, none(string))
  except RlpError as ex:
    error "JsonTracer captureOpEnd", msg=ex.msg

method captureFault*(ctx: JsonTracer, pc: int,
                     op: Op, gas: GasInt, refund: GasInt,
                     rData: openArray[byte],
                     depth: int, error: Option[string]) {.gcsafe.} =
  try:
    ctx.captureOpImpl(pc, op, gas, refund, rData, depth, error)
  except RlpError as ex:
    error "JsonTracer captureOpEnd", msg=ex.msg

proc close*(ctx: JsonTracer) =
  ctx.stream.close()

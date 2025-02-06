# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[json, sets, streams, strutils],
  eth/common/eth_types,
  eth/rlp,
  stew/byteutils,
  results,
  chronicles,
  ".."/[types, memory, stack],
  ../interpreter/op_codes,
  ../../db/ledger

type
  JsonTracer* = ref object of TracerRef
    stream: Stream
    pretty: bool
    gas: GasInt
    pc: int
    stack: JsonNode
    storageKeys: seq[HashSet[UInt256]]
    index: int
    node: JsonNode

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeHex(x: SomeInteger): JsonNode =
  %("0x" & x.toHex.stripLeadingZeros.toLowerAscii)

proc encodeHex(x: UInt256): string =
  "0x" & x.dumpHex.stripLeadingZeros

proc `%`(x: openArray[byte]): JsonNode =
  if x.len == 0:
    %("")
  else:
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

proc captureOpImpl(ctx: JsonTracer, c: Computation, pc: int,
                   op: Op, gas: GasInt, refund: int64,
                   rData: openArray[byte], depth: int, error: Opt[string]) {.gcsafe.} =
  let
    gasCost = ctx.gas - gas

  var res = %{
    "pc": %(ctx.pc),
    "op": %(op.int),
    "gas": encodeHex(ctx.gas),
    "gasCost": encodeHex(gasCost),
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
      var ledger = c.vmState.ledger
      for key in ctx.storage(c.msg.depth):
        let value = ledger.getStorage(c.msg.contractAddress, key)
        storage[key.encodeHex] = %(value.encodeHex)
    res["storage"] = storage

  res["depth"] = %(depth)
  res["refund"] = %(refund)
  res["opName"] = %(($op).toUpperAscii)

  if error.isSome:
    res["error"] = %(error.get)

  ctx.node = res

proc newJsonTracer*(stream: Stream, flags: set[TracerFlags], pretty: bool): JsonTracer =
  JsonTracer(
    flags: flags,
    stream: stream,
    pretty: pretty
  )

method capturePrepare*(ctx: JsonTracer, comp: Computation, depth: int) {.gcsafe.} =
  if depth >= ctx.storageKeys.len:
    let prevLen = ctx.storageKeys.len
    ctx.storageKeys.setLen(depth + 1)
    for i in prevLen ..< ctx.storageKeys.len - 1:
      ctx.storageKeys[i] = HashSet[UInt256]()

  ctx.storageKeys[depth] = HashSet[UInt256]()

# Top call frame
method captureStart*(ctx: JsonTracer, comp: Computation,
                     sender: Address, to: Address,
                     create: bool, input: openArray[byte],
                     gasLimit: GasInt, value: UInt256) {.gcsafe.} =
  discard

method captureEnd*(ctx: JsonTracer, comp: Computation, output: openArray[byte],
                   gasUsed: GasInt, error: Opt[string]) {.gcsafe.} =
  var res = %{
    "output": %(output),
    "gasUsed": encodeHex(gasUsed)
  }
  if error.isSome:
    res["error"] = %(error.get())
  ctx.writeJson(res)

# Opcode level
method captureOpStart*(ctx: JsonTracer, c: Computation,
                       fixed: bool, pc: int, op: Op, gas: GasInt,
                       depth: int): int {.gcsafe.} =
  ctx.gas = gas
  ctx.pc = pc

  if TracerFlags.DisableStack notin ctx.flags:
    ctx.stack = newJArray()
    for v in c.stack:
      ctx.stack.add(%(v.encodeHex))

  if TracerFlags.DisableStorage notin ctx.flags and op == Sstore:
    if c.stack.len > 1:
      ctx.rememberStorageKey(c.msg.depth,
        c.stack[^1, UInt256].expect("stack constains more than 2 elements"))

  ctx.captureOpImpl(c, pc, op, 0, 0, [], depth, Opt.none(string))

  # make sure captureOpEnd get the right opIndex
  result = ctx.index
  inc ctx.index

method captureGasCost*(ctx: JsonTracer, comp: Computation,
                       fixed: bool, op: Op, gasCost: GasInt, gasRemaining: GasInt,
                       depth: int) {.gcsafe.} =
  doAssert(ctx.node.isNil.not)
  let res = ctx.node
  res["gasCost"] = encodeHex(gasCost)

  if gasCost <= gasRemaining and not fixed:
    ctx.writeJson(res)
    ctx.node = nil
  # else:
  # OOG will be handled by captureFault
  # opcode with fixed gasCost will be handled by captureOpEnd

method captureOpEnd*(ctx: JsonTracer, comp: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: int64,
                     rData: openArray[byte],
                     depth: int, opIndex: int) {.gcsafe.} =
  if fixed:
    doAssert(ctx.node.isNil.not)
    let res = ctx.node
    res["refund"] = %(refund)

    if TracerFlags.DisableReturnData notin ctx.flags:
      res["returnData"] = %(rData)

    ctx.writeJson(res)
    ctx.node = nil
    return

method captureFault*(ctx: JsonTracer, comp: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: int64,
                     rData: openArray[byte],
                     depth: int, error: Opt[string]) {.gcsafe.} =

  if ctx.node.isNil.not:
    let res = ctx.node
    res["refund"] = %(refund)

    if TracerFlags.DisableReturnData notin ctx.flags:
      res["returnData"] = %(rData)

    if error.isSome:
      res["error"] = %(error.get)

    ctx.writeJson(res)
    ctx.node = nil
    return

  ctx.captureOpImpl(comp, pc, op, gas, refund, rData, depth, error)
  doAssert(ctx.node.isNil.not)
  ctx.writeJson(ctx.node)
  ctx.node = nil

proc close*(ctx: JsonTracer) {.raises: [IOError, OSError].} =
  ctx.stream.close()

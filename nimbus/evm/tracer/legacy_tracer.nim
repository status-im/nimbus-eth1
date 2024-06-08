# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Populates the tracer API methods
## ================================
##
## The module name `legacy_tracer` is probably a misonmer as it also works
## with the new APIs for `CoreDb` and `Ledger`.
##

import
  std/[json, sets, strutils, hashes],
  eth/common/eth_types,
  eth/rlp,
  stew/byteutils,
  chronicles,
  ".."/[types, memory, stack],
  ../interpreter/op_codes,
  ../../db/ledger,
  ../evm_errors

type
  LegacyTracer* = ref object of TracerRef
    trace: JsonNode
    accounts: HashSet[EthAddress]
    storageKeys: seq[HashSet[UInt256]]
    gas: GasInt

proc hash*(x: UInt256): Hash =
  result = hash(x.toByteArrayBE)

proc rememberStorageKey(ctx: LegacyTracer, compDepth: int, key: UInt256) =
  ctx.storageKeys[compDepth].incl key

iterator storage(ctx: LegacyTracer, compDepth: int): UInt256 =
  doAssert compDepth >= 0 and compDepth < ctx.storageKeys.len
  for key in ctx.storageKeys[compDepth]:
    yield key

proc newLegacyTracer*(flags: set[TracerFlags]): LegacyTracer =
  let trace = newJObject()

  # make appear at the top of json object
  trace["gas"] = %0
  trace["failed"] = %false
  trace["returnValue"] = %""
  trace["structLogs"] = newJArray()

  LegacyTracer(
    flags: flags,
    trace: trace
  )

method capturePrepare*(ctx: LegacyTracer, comp: Computation, depth: int) {.gcsafe.} =
  if depth >= ctx.storageKeys.len:
    let prevLen = ctx.storageKeys.len
    ctx.storageKeys.setLen(depth + 1)
    for i in prevLen ..< ctx.storageKeys.len - 1:
      ctx.storageKeys[i] = initHashSet[UInt256]()

  ctx.storageKeys[depth] = initHashSet[UInt256]()

# Opcode level
method captureOpStart*(ctx: LegacyTracer, c: Computation,
                       fixed: bool, pc: int, op: Op, gas: GasInt,
                       depth: int): int {.gcsafe.} =
  try:
    let
      j = newJObject()
    ctx.trace["structLogs"].add(j)

    j["op"] = %(($op).toUpperAscii)
    j["pc"] = %(c.code.pc - 1)
    j["depth"] = %(c.msg.depth + 1)
    j["gas"] = %(gas)
    ctx.gas = gas

    # log stack
    if TracerFlags.DisableStack notin ctx.flags:
      let stack = newJArray()
      for v in c.stack:
        stack.add(%v.dumpHex())
      j["stack"] = stack

    # log memory
    if TracerFlags.DisableMemory notin ctx.flags:
      let mem = newJArray()
      const chunkLen = 32
      let numChunks = c.memory.len div chunkLen
      for i in 0 ..< numChunks:
        let memHex = c.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex()
        mem.add(%(memHex.toUpperAscii))
      j["memory"] = mem

    if TracerFlags.EnableAccount in ctx.flags:
      case op
      of Call, CallCode, DelegateCall, StaticCall:
        if c.stack.len > 2:
          ctx.accounts.incl c.stack[^2, EthAddress].expect("stack constains more than 2 elements")
      of ExtCodeCopy, ExtCodeSize, Balance, SelfDestruct:
        if c.stack.len > 1:
          ctx.accounts.incl c.stack[^1, EthAddress].expect("stack is not empty")
      else:
        discard

    if TracerFlags.DisableStorage notin ctx.flags:
      if op == Sstore:
        if c.stack.len > 1:
          ctx.rememberStorageKey(c.msg.depth,
            c.stack[^1, UInt256].expect("stack is not empty"))

    result = ctx.trace["structLogs"].len - 1
  except KeyError as ex:
    error "LegacyTracer captureOpStart", msg=ex.msg
  except ValueError as ex:
    error "LegacyTracer captureOpStart", msg=ex.msg

method captureOpEnd*(ctx: LegacyTracer, c: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: GasInt,
                     rData: openArray[byte],
                     depth: int, opIndex: int) {.gcsafe.} =
  try:
    let
      j = ctx.trace["structLogs"].elems[opIndex]

    # TODO: figure out how to get storage
    # when contract execution interrupted by exception
    if TracerFlags.DisableStorage notin ctx.flags:
      var storage = newJObject()
      if c.msg.depth < ctx.storageKeys.len:
        var stateDB = c.vmState.stateDB
        for key in ctx.storage(c.msg.depth):
          let value = stateDB.getStorage(c.msg.contractAddress, key)
          storage[key.dumpHex] = %(value.dumpHex)
        j["storage"] = storage

    j["gasCost"] = %(ctx.gas - gas)

    if op in {Return, Revert} and TracerFlags.DisableReturnData notin ctx.flags:
      let returnValue = %("0x" & toHex(c.output))
      j["returnValue"] = returnValue
      ctx.trace["returnValue"] = returnValue
  except KeyError as ex:
    error "LegacyTracer captureOpEnd", msg=ex.msg
  except RlpError as ex:
    error "LegacyTracer captureOpEnd", msg=ex.msg

method captureFault*(ctx: LegacyTracer, comp: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: GasInt,
                     rData: openArray[byte],
                     depth: int, error: Opt[string]) {.gcsafe.} =
  try:
    if ctx.trace["structLogs"].elems.len > 0:
      let j = ctx.trace["structLogs"].elems[^1]
      j["error"] = %(comp.error.info)
      j["gasCost"] = %(ctx.gas - gas)

    ctx.trace["failed"] = %true
  except KeyError as ex:
    error "LegacyTracer captureOpEnd", msg=ex.msg

proc getTracingResult*(ctx: LegacyTracer): JsonNode =
  ctx.trace

iterator tracedAccounts*(ctx: LegacyTracer): EthAddress =
  for acc in ctx.accounts:
    yield acc

iterator tracedAccountsPairs*(ctx: LegacyTracer): (int, EthAddress) =
  var idx = 0
  for acc in ctx.accounts:
    yield (idx, acc)
    inc idx

proc removeTracedAccounts*(ctx: LegacyTracer, accounts: varargs[EthAddress]) =
  for acc in accounts:
    ctx.accounts.excl acc

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, parseutils, sets, macros,
  ../logging, ../constants, ./interpreter/opcode_values

type
  CodeStream* = ref object
    bytes*: seq[byte]
    depthProcessed: int
    invalidPositions: HashSet[int]
    pc*: int
    logger: Logger
    cached: seq[(int, Op, string)]

proc `$`*(b: byte): string =
  $(b.int)

proc newCodeStream*(codeBytes: seq[byte]): CodeStream =
  new(result)
  result.bytes = codeBytes
  result.pc = 0
  result.invalidPositions = initSet[int]()
  result.depthProcessed = 0
  result.cached = @[]
  result.logger = logging.getLogger("vm.code_stream")

proc newCodeStream*(codeBytes: string): CodeStream =
  newCodeStream(codeBytes.mapIt(it.byte))

proc newCodeStreamFromUnescaped*(code: string): CodeStream =
  # from 0xunescaped
  var codeBytes: seq[byte] = @[]
  for z, c in code[2..^1]:
    if z mod 2 == 1:
      var value: int
      discard parseHex(&"0x{code[z+1..z+2]}", value)
      codeBytes.add(value.byte)
  newCodeStream(codeBytes)

proc read*(c: var CodeStream, size: int): seq[byte] =
  if c.pc + size - 1 < c.bytes.len:
    result = c.bytes[c.pc .. c.pc + size - 1]
    c.pc += size
  else:
    result = @[]
    c.pc = c.bytes.len

proc len*(c: CodeStream): int =
  len(c.bytes)

proc next*(c: var CodeStream): Op =
  var nextOpcode = c.read(1)
  if nextOpcode.len != 0:
    return Op(nextOpcode[0])
  else:
    return Op.STOP

iterator items*(c: var CodeStream): Op =
  var nextOpcode = c.next()
  while nextOpcode != Op.STOP:
    yield nextOpcode
    nextOpcode = c.next()

proc `[]`*(c: CodeStream, offset: int): Op =
  Op(c.bytes[offset])

proc peek*(c: var CodeStream): Op =
  var currentPc = c.pc
  result = c.next()
  c.pc = currentPc

proc updatePc*(c: var CodeStream, value: int) =
  c.pc = min(value, len(c))

when false:
  template seek*(cs: var CodeStream, pc: int, handler: untyped): untyped =
    var anchorPc = cs.pc
    cs.pc = pc
    try:
      var c {.inject.} = cs
      handler
    finally:
      cs.pc = anchorPc

proc isValidOpcode*(c: var CodeStream, position: int): bool =
  if position >= len(c):
    return false
  if position in c.invalidPositions:
    return false
  if position <= c.depthProcessed:
    return true
  else:
    var i = c.depthProcessed
    while i <= position:
      var opcode = Op(c[i])
      if opcode >= Op.PUSH1 and opcode <= Op.PUSH32:
        var leftBound = (i + 1)
        var rightBound = leftBound + (opcode.int - 95)
        for z in leftBound ..< rightBound:
          c.invalidPositions.incl(z)
        i = rightBound
      else:
        c.depthProcessed = i
        i += 1
    if position in c.invalidPositions:
      return false
    else:
      return true

proc decompile*(original: var CodeStream): seq[(int, Op, string)] =
  # behave as https://etherscan.io/opcode-tool
  # TODO
  if original.cached.len > 0:
    return original.cached
  result = @[]
  var c = newCodeStream(original.bytes)
  while true:
    var op = c.next
    if op >= PUSH1 and op <= PUSH32:
      let bytes = c.read(op.int - 95)
      result.add((c.pc - 1, op, "0x" & bytes.mapIt($(it.BiggestInt.toHex(2))).join("")))
    elif op != Op.Stop:
      result.add((c.pc - 1, op, ""))
    else:
      result.add((-1, Op.STOP, ""))
      break
  original.cached = result

proc displayDecompiled*(c: CodeStream) =
  var copy = c
  let opcodes = copy.decompile()
  for op in opcodes:
    echo op[0], " ", op[1], " ", op[2]


proc hasSStore*(c: var CodeStream): bool =
  let opcodes = c.decompile()
  result = opcodes.anyIt(it[1] == SSTORE)

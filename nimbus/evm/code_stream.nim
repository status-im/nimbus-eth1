# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strformat, strutils, sequtils, parseutils, sets],
  chronicles,
  eth/common,
  stew/[results, endians2],
  stew/ranges/ptr_arith,
  ../utils/eof,
  ./interpreter/op_codes

logScope:
  topics = "vm code_stream"

type
  CodeView = ptr UncheckedArray[byte]

  CodeStream* = ref object
    # pre EOF byte code
    legacyCode*: seq[byte]

    # view into legacyCode or
    # into one of EOF code section
    codeView: CodeView

    # length of legacy code or
    # one of EOF code section
    codeLen: int

    depthProcessed: int
    invalidPositions: HashSet[int]
    pc*: int
    cached: seq[(int, Op, string)]

    # EOF container
    container*: Container

    # EOF code section index
    section: int

proc `$`*(b: byte): string =
  $(b.int)

proc newCodeStream*(codeBytes: seq[byte]): CodeStream =
  new(result)
  shallowCopy(result.legacyCode, codeBytes)
  result.pc = 0
  result.invalidPositions = initHashSet[int]()
  result.depthProcessed = 0
  result.cached = @[]
  result.codeLen = result.legacyCode.len
  if result.codeLen > 0:
    result.codeView = cast[CodeView](addr result.legacyCode[0])

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
  # TODO: use openArray[bytes]
  if c.pc + size - 1 < c.codeLen:
    result = @(makeOpenArray(addr c.codeView[c.pc], byte, size))
    c.pc += size
  else:
    result = @[]
    c.pc = c.codeLen

proc readVmWord*(c: var CodeStream, n: int): UInt256 =
  ## Reads `n` bytes from the code stream and pads
  ## the remaining bytes with zeros.
  let resultBytes = cast[ptr array[32, byte]](addr result)

  let last = min(c.pc + n, c.codeLen)
  let toWrite = last - c.pc
  for i in 0 ..< toWrite : resultBytes[i] = c.codeView[last - i - 1]
  c.pc = last

proc readInt16*(c: var CodeStream): int =
  let x = uint16.fromBytesBE(makeOpenArray(addr c.codeView[c.pc], byte, 2))
  result = cast[int16](x).int
  c.pc += 2

proc readByte*(c: var CodeStream): byte =
  result = c.codeView[c.pc]
  inc c.pc

proc len*(c: CodeStream): int =
  if c.container.code.len > 0:
    c.container.size
  else:
    c.legacyCode.len

proc setSection*(c: CodeStream, sec: int) =
  if sec < c.container.code.len:
    c.codeLen = c.container.code[sec].len
    if c.codeLen > 0:
      c.codeView = cast[CodeView](addr c.container.code[sec][0])
    c.section = sec

proc parseEOF*(c: CodeStream): Result[void, EOFV1Error] =
  result = decode(c.container, c.legacyCode)
  if result.isOk:
    c.setSection(0)

func hasEOFCode*(c: CodeStream): bool =
  hasEOFMagic(c.legacyCode)

proc next*(c: var CodeStream): Op =
  if c.pc != c.codeLen:
    result = Op(c.codeView[c.pc])
    inc c.pc
  else:
    result = Stop

iterator items*(c: var CodeStream): Op =
  var nextOpcode = c.next()
  while nextOpcode != Op.STOP:
    yield nextOpcode
    nextOpcode = c.next()

proc `[]`*(c: CodeStream, offset: int): Op =
  Op(c.codeView[offset])

proc peek*(c: var CodeStream): Op =
  if c.pc < c.codeLen:
    result = Op(c.codeView[c.pc])
  else:
    result = Stop

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

proc isValidOpcode*(c: CodeStream, position: int): bool =
  if position >= c.codeLen:
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
  var c = newCodeStream(original.legacyCode)
  if c.hasEOFCode:
    let res = c.parseEOF
    if res.isErr:
      return

  while true:
    var op = c.next
    if op >= Push1 and op <= Push32:
      let bytes = c.read(op.int - 95)
      result.add((c.pc - 1, op, "0x" & bytes.mapIt($(it.BiggestInt.toHex(2))).join("")))
    elif op != Op.Stop:
      result.add((c.pc - 1, op, ""))
    else:
      result.add((-1, Op.Stop, ""))
      break
  original.cached = result

proc displayDecompiled*(c: CodeStream) =
  var copy = c
  let opcodes = copy.decompile()
  for op in opcodes:
    echo op[0], " ", op[1], " ", op[2]

proc hasSStore*(c: var CodeStream): bool =
  let opcodes = c.decompile()
  result = opcodes.anyIt(it[1] == Sstore)

proc atEnd*(c: CodeStream): bool =
  result = c.pc >= c.codeLen

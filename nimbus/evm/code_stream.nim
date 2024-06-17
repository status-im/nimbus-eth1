# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, strutils, sequtils, parseutils,
  eth/common,
  ./interpreter/op_codes

logScope:
  topics = "vm code_stream"

type
  CodeStream* = ref object
    bytes*: seq[byte]
    depthProcessed: int
    invalidPositions: seq[byte] # bit seq of invalid jump positions
    pc*: int

proc `$`*(b: byte): string =
  $(b.int)

template bitpos(pos: int): (int, byte) =
  (pos shr 3, 1'u8 shl (pos and 0x07))

proc newCodeStream*(codeBytes: sink seq[byte]): CodeStream =
  new(result)
  result.bytes = system.move(codeBytes)
  result.pc = 0
  result.invalidPositions = newSeq[byte]((result.bytes.len + 7) div 8)
  result.depthProcessed = 0

proc invalidPosition(c: CodeStream, pos: int): bool =
  let (bpos, bbit) = bitpos(pos)
  (c.invalidPositions[bpos] and bbit) > 0

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

template read*(c: CodeStream, size: int): openArray[byte] =
  # TODO: use openArray[bytes]
  if c.pc + size - 1 < c.bytes.len:
    let pos = c.pc
    c.pc += size
    c.bytes.toOpenArray(pos, pos + size - 1)
  else:
    c.pc = c.bytes.len
    c.bytes.toOpenArray(0, -1)

proc readVmWord*(c: var CodeStream, n: int): UInt256 =
  ## Reads `n` bytes from the code stream and pads
  ## the remaining bytes with zeros.
  let result_bytes = cast[ptr array[32, byte]](addr result)

  let last = min(c.pc + n, c.bytes.len)
  let toWrite = last - c.pc
  for i in 0 ..< toWrite : result_bytes[i] = c.bytes[last - i - 1]
  c.pc = last

proc len*(c: CodeStream): int =
  len(c.bytes)

proc next*(c: var CodeStream): Op =
  if c.pc != c.bytes.len:
    result = Op(c.bytes[c.pc])
    inc c.pc
  else:
    result = Op.Stop

iterator items*(c: var CodeStream): Op =
  var nextOpcode = c.next()
  while nextOpcode != Op.Stop:
    yield nextOpcode
    nextOpcode = c.next()

proc `[]`*(c: CodeStream, offset: int): Op =
  Op(c.bytes[offset])

proc peek*(c: var CodeStream): Op =
  if c.pc < c.bytes.len:
    Op(c.bytes[c.pc])
  else:
    Op.Stop

proc updatePc*(c: var CodeStream, value: int) =
  c.pc = min(value, len(c))

proc isValidOpcode*(c: CodeStream, position: int): bool =
  if position >= len(c):
    false
  elif c.invalidPosition(position):
    false
  elif position <= c.depthProcessed:
    true
  else:
    var i = c.depthProcessed
    while i <= position:
      var opcode = Op(c[i])
      if opcode >= Op.Push1 and opcode <= Op.Push32:
        var leftBound = (i + 1)
        var rightBound = leftBound + (opcode.int - 95)
        for z in leftBound ..< rightBound:
          let (bpos, bbit) = bitpos(z)
          c.invalidPositions[bpos] = c.invalidPositions[bpos] or bbit
        i = rightBound
      else:
        i += 1
    c.depthProcessed = i - 1

    not c.invalidPosition(position)

proc decompile*(original: CodeStream): seq[(int, Op, string)] =
  # behave as https://etherscan.io/opcode-tool
  var c = newCodeStream(original.bytes)
  while true:
    var op = c.next
    if op >= Push1 and op <= Push32:
      result.add(
        (c.pc - 1, op, "0x" & c.read(op.int - 95).mapIt($(it.BiggestInt.toHex(2))).join("")))
    elif op != Op.Stop:
      result.add((c.pc - 1, op, ""))
    else:
      result.add((-1, Op.Stop, ""))
      break

proc atEnd*(c: CodeStream): bool =
  c.pc >= c.bytes.len

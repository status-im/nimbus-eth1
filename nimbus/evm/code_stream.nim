# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import chronicles, eth/common, stew/byteutils, ./interpreter/op_codes, ./code_bytes

export code_bytes

type CodeStream* = object
  code: CodeBytesRef
  pc*: int

func init*(T: type CodeStream, code: CodeBytesRef): T =
  T(code: code)

func init*(T: type CodeStream, code: sink seq[byte]): T =
  T(code: CodeBytesRef.init(move(code)))

func init*(T: type CodeStream, code: openArray[byte]): T =
  T(code: CodeBytesRef.init(code))

func init*(T: type CodeStream, code: openArray[char]): T =
  T(code: CodeBytesRef.init(code))

template read*(c: var CodeStream, size: int): openArray[byte] =
  let
    pos = c.pc
    last = pos + size

  if last <= c.bytes.len:
    c.pc = last
    c.code.bytes.toOpenArray(pos, last - 1)
  else:
    c.pc = c.bytes.len
    c.code.bytes.toOpenArray(pos, c.bytes.high)

func readVmWord*(c: var CodeStream, n: static int): UInt256 {.inline, noinit.} =
  ## Reads `n` bytes from the code stream and pads
  ## the remaining bytes with zeros.
  UInt256.fromBytesBE(c.read(n))

func len*(c: CodeStream): int =
  len(c.code)

template next*(c: var CodeStream): Op =
  # Retrieve the next opcode (or stop) - this is a hot spot in the interpreter
  # and must be kept small for performance
  let
    # uint: range checked manually -> benefit from smaller codegen
    pc = uint(c.pc)
    bytes {.cursor.} = c.code.bytes
  if pc < uint(bytes.len):
    let op = Op(bytes[pc])
    c.pc = cast[int](pc + 1)
    op
  else:
    Op.Stop

iterator items*(c: var CodeStream): Op =
  var nextOpcode = c.next()
  while nextOpcode != Op.Stop:
    yield nextOpcode
    nextOpcode = c.next()

func `[]`*(c: CodeStream, offset: int): Op =
  Op(c.code.bytes[offset])

func peek*(c: var CodeStream): Op =
  if c.pc < c.code.bytes.len:
    Op(c.code.bytes[c.pc])
  else:
    Op.Stop

func updatePc*(c: var CodeStream, value: int) =
  c.pc = min(value, len(c))

func isValidOpcode*(c: CodeStream, position: int): bool =
  c.code.isValidOpcode(position)

func bytes*(c: CodeStream): lent seq[byte] =
  c.code.bytes()

func atEnd*(c: CodeStream): bool =
  c.pc >= c.code.bytes.len

proc decompile*(original: CodeStream): seq[(int, Op, string)] =
  # behave as https://etherscan.io/opcode-tool
  var c = CodeStream.init(original.bytes)
  while not c.atEnd:
    var op = c.next
    if op >= Push1 and op <= Push32:
      result.add((c.pc - 1, op, "0x" & c.read(op.int - 95).toHex))
    elif op != Op.Stop:
      result.add((c.pc - 1, op, ""))
    else:
      result.add((-1, Op.Stop, ""))

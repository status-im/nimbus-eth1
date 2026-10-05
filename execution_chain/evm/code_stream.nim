# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import stint, stew/byteutils, ./interpreter/op_codes, ./code_bytes

export code_bytes

type CodeStream* = object
  code: CodeBytesRef
  data: ptr UncheckedArray[byte]
  codeLen: int
  pc*: int

func init*(T: type CodeStream, code: CodeBytesRef): T =
  T(code: code, data: code.codeData, codeLen: code.len)

func init*(T: type CodeStream, code: sink seq[byte]): T =
  CodeStream.init(CodeBytesRef.init(move(code)))

func init*(T: type CodeStream, code: openArray[byte]): T =
  CodeStream.init(CodeBytesRef.init(code))

func init*(T: type CodeStream, code: openArray[char]): T =
  CodeStream.init(CodeBytesRef.init(code))

template read*(c: var CodeStream, size: int): openArray[byte] =
  let
    pos = c.pc
    last = min(pos + size, c.codeLen)

  c.pc = last
  c.data.toOpenArray(pos, last - 1)

template readVmWord*(c: var CodeStream, n: static int): UInt256 =
  ## Reads `n` bytes from the code stream and pads
  ## the remaining bytes with zeros.
  when n <= 8:
    # Values of up to 8 bytes fit a single limb - folding the bytes directly
    # avoids the generic openArray conversion on this hot path (PUSH1..PUSH8)
    block:
      let
        pos = c.pc
        last = min(pos + n, c.codeLen)
        data = c.data
      var v = 0'u64
      {.push checks: off.}
      for i in pos ..< last:
        v = (v shl 8) or uint64(data[i])
      {.pop.}
      c.pc = last
      v.u256
  else:
    UInt256.fromBytesBE(c.read(n))

func len*(c: CodeStream): int =
  c.codeLen

template next*(c: var CodeStream): Op =
  # Retrieve the next opcode (or stop) - this is a hot spot in the interpreter
  # and must be kept small for performance
  let pc = c.pc
  if pc < c.codeLen:
    {.push checks: off.}
    let op = Op(c.data[pc])
    c.pc = pc + 1
    {.pop.}
    op
  else:
    Op.Stop

iterator items*(c: var CodeStream): Op =
  var nextOpcode = c.next()
  while nextOpcode != Op.Stop:
    yield nextOpcode
    nextOpcode = c.next()

func `[]`*(c: CodeStream, offset: int): Op =
  if offset >= 0 and offset < c.codeLen:
    {.push checks: off.}
    let op = Op(c.data[offset])
    {.pop.}
    op
  else:
    Op.Stop

func peek*(c: var CodeStream): Op =
  c[c.pc]

func updatePc*(c: var CodeStream, value: int) =
  c.pc = min(value, c.codeLen)

func isValidOpcode*(c: CodeStream, position: int): bool =
  c.code.isValidOpcode(position)

template bytes*(c: CodeStream): openArray[byte] =
  c.code.bytes()

func atEnd*(c: CodeStream): bool =
  c.pc >= c.codeLen

func getImmediateByte*(c: var CodeStream): int =
  var x = 0
  if c.pc < c.codeLen:
    {.push checks: off.}
    x = int(c.data[c.pc])
    {.pop.}
    inc c.pc
  x

proc decompile*(original: CodeStream): seq[(int, Op, string)] =
  # behave as https://etherscan.io/opcode-tool
  var c = CodeStream.init(original.bytes)
  while not c.atEnd:
    var op = c.next
    if op >= Push1 and op <= Push32:
      result.add((c.pc - 1, op, "0x" & c.read(op.int - 95).toHex))
    elif op in {DupN, SwapN, Exchange}:
      result.add((c.pc - 1, op, $c.getImmediateByte))
    elif op != Op.Stop:
      result.add((c.pc - 1, op, ""))
    else:
      result.add((-1, Op.Stop, ""))

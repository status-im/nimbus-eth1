# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  interpreter/op_codes

const
  set2BitsMask = uint16(0b11)
  set3BitsMask = uint16(0b111)
  set4BitsMask = uint16(0b1111)
  set5BitsMask = uint16(0b1_1111)
  set6BitsMask = uint16(0b11_1111)
  set7BitsMask = uint16(0b111_1111)

# bitvec is a bit vector which maps bytes in a program.
# An unset bit means the byte is an opcode, a set bit means
# it's data (i.e. argument of PUSHxx).
type
  Bitvec* = seq[byte]

proc set1(bits: var Bitvec, pos: int) =
  let x = bits[pos div 8]
  bits[pos div 8] = x or byte(1 shl (pos mod 8))

proc setN(bits: var Bitvec, flag: uint16, pos: int) =
  let z = pos div 8
  let a = flag shl (pos mod 8)
  let x = bits[z]
  bits[z] = x or byte(a)
  let b = byte(a shr 8)
  if b != 0:
    bits[z+1] = b

proc set8(bits: var Bitvec, pos: int) =
  let z = pos div 8
  let a = byte(0xFF shl (pos mod 8))
  bits[z] = bits[z] or a
  bits[z+1] = not a

proc set16(bits: var Bitvec, pos: int) =
  let z = pos div 8
  let a = byte(0xFF shl (pos mod 8))
  bits[z] = bits[z] or a
  bits[z+1] = 0xFF
  bits[z+2] = not a

# codeSegment checks if the position is in a code segment.
proc codeSegment*(bits: Bitvec, pos: int): bool =
  ((bits[pos div 8] shr (pos mod 8)) and 1) == 0

# codeBitmapInternal is the internal implementation of codeBitmap.
# It exists for the purpose of being able to run benchmark tests
# without dynamic allocations affecting the results.
proc codeBitmapInternal(bits: var Bitvec; code: openArray[byte]) =
  var pc = 0
  while pc < code.len:
    let op = Op(code[pc])
    inc pc

    if op < PUSH1:
      continue

    var numbits = op.int - PUSH1.int + 1
    if numbits >= 8:
      while numbits >= 16:
        bits.set16(pc)
        pc += 16
        numbits -= 16

      while numbits >= 8:
        bits.set8(pc)
        pc += 8
        numbits -= 8

    case numbits
    of 1: bits.set1(pc)
    of 2: bits.setN(set2BitsMask, pc)
    of 3: bits.setN(set3BitsMask, pc)
    of 4: bits.setN(set4BitsMask, pc)
    of 5: bits.setN(set5BitsMask, pc)
    of 6: bits.setN(set6BitsMask, pc)
    of 7: bits.setN(set7BitsMask, pc)
    else: discard
    pc += numbits

# codeBitmap collects data locations in code.
proc codeBitmap*(code: openArray[byte]): Bitvec =
  # The bitmap is 4 bytes longer than necessary, in case the code
  # ends with a PUSH32, the algorithm will push zeroes onto the
  # bitvector outside the bounds of the actual code.
  let len = (code.len div 8)+1+4
  result = newSeq[byte](len)
  result.codeBitmapInternal(code)

# eofCodeBitmapInternal is the internal implementation of codeBitmap for EOF
# code validation.
proc eofCodeBitmapInternal(bits: var Bitvec; code: openArray[byte]) =
  var pc = 0
  while pc < code.len:
    let op = Op(code[pc])
    inc pc

    # RJUMP and RJUMPI always have 2 byte operand.
    if op == RJUMP or op == RJUMPI:
      bits.setN(set2BitsMask, pc)
      pc += 2
      continue

    var numbits = 0
    if op >= PUSH1 and op <= PUSH32:
      numbits = op.int - PUSH1.int + 1
    elif op == RJUMPV:
      # RJUMPV is unique as it has a variable sized operand.
      # The total size is determined by the count byte which
      # immediate proceeds RJUMPV. Truncation will be caught
      # in other validation steps -- for now, just return a
      # valid bitmap for as much of the code as is
      # available.
      if pc >= code.len:
        # Count missing, no more bits to mark.
        return
      numbits = code[pc].int*2 + 1
      if pc+numbits > code.len:
        # Jump table is truncated, mark as many bits
        # as possible.
        numbits = code.len - pc
    else:
      # If not PUSH (the int8(op) > int(PUSH32) is always false).
      continue

    if numbits >= 8:
      while numbits >= 16:
        bits.set16(pc)
        pc += 16
        numbits -= 16

      while numbits >= 8:
        bits.set8(pc)
        pc += 8
        numbits -= 8

    case numbits
    of 1: bits.set1(pc)
    of 2: bits.setN(set2BitsMask, pc)
    of 3: bits.setN(set3BitsMask, pc)
    of 4: bits.setN(set4BitsMask, pc)
    of 5: bits.setN(set5BitsMask, pc)
    of 6: bits.setN(set6BitsMask, pc)
    of 7: bits.setN(set7BitsMask, pc)
    else: discard
    pc += numbits

# eofCodeBitmap collects data locations in code.
proc eofCodeBitmap*(code: openArray[byte]): Bitvec =
  # The bitmap is 4 bytes longer than necessary, in case the code
  # ends with a PUSH32, the algorithm will push zeroes onto the
  # bitvector outside the bounds of the actual code.
  let len = (code.len div 8)+1+4
  result = newSeq[byte](len)
  result.eofCodeBitmapInternal(code)

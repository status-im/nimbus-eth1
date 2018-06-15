# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stint, ./utils/[macros_procs_opcodes, utils_numeric],
  ./gas_meter, ./opcode_values

# ##################################
# 0s: Stop and Arithmetic Operations

op add, FkFrontier, inline = true, lhs, rhs:
  ## 0x01, Addition
  push: lhs + rhs

op mul, FkFrontier, inline = true, lhs, rhs:
  ## 0x02, Multiplication
  push: lhs * rhs

op sub, FkFrontier, inline = true, lhs, rhs:
  ## 0x03, Substraction
  push: lhs - rhs

op divide, FkFrontier, inline = true, lhs, rhs:
  ## 0x04, Division
  push:
    if rhs == 0: zero(Uint256)
    else:        lhs div rhs

op sdiv, FkFrontier, inline = true, lhs, rhs:
  ## 0x05, Signed division
  push:
    if rhs == 0: zero(Uint256)
    else:
      pseudoSignedToUnsigned(
        lhs.unsignedToPseudoSigned div rhs.unsignedToPseudoSigned
      )

op modulo, FkFrontier, inline = true, lhs, rhs:
  ## 0x06, Modulo
  push:
    if rhs == 0: zero(Uint256)
    else:        lhs mod rhs

op smod, FkFrontier, inline = true, lhs, rhs:
  ## 0x07, Signed modulo
  push:
    if rhs == 0: zero(UInt256)
    else:
      pseudoSignedToUnsigned(
        lhs.unsignedToPseudoSigned mod rhs.unsignedToPseudoSigned
      )

op addmod, FkFrontier, inline = true, lhs, rhs, modulus:
  ## 0x08, Modulo addition
  ## Intermediate computations do not roll over at 2^256
  push:
    if modulus == 0: zero(UInt256)
    else: addmod(lhs, rhs, modulus)

op mulmod, FkFrontier, inline = true, lhs, rhs, modulus:
  ## 0x09, Modulo multiplication
  ## Intermediate computations do not roll over at 2^256
  push:
    if modulus == 0: zero(UInt256)
    else: mulmod(lhs, rhs, modulus)

op exp, FkFrontier, inline = true, base, exponent:
  ## 0x0A, Exponentiation
  computation.gasMeter.consumeGas(
    computation.gasCosts[Exp].d_handler(exponent),
    reason="EXP: exponent bytes"
    )
  push:
    if base == 0: zero(UInt256)
    else: base.pow(exponent)

op signExtend, FkFrontier, inline = true, bits, value:
  ## 0x0B, Sign extend
  ## Extend length of two’s complement signed integer.

  var res: UInt256
  if bits <= 31.u256:
    let
      testBit = bits.toInt * 8 + 7
      bitPos = (1 shl testBit)
      mask = u256(bitPos - 1)
    if not isZero(value and bitPos.u256):
      res = value or (not mask)
    else:
      res = value and mask
  else:
    res = value

  push: res

# ##########################################
# 10s: Comparison & Bitwise Logic Operations

op lt, FkFrontier, inline = true, lhs, rhs:
  ## 0x10, Less-than comparison
  push: (lhs < rhs).uint.u256

op gt, FkFrontier, inline = true, lhs, rhs:
  ## 0x11, Greater-than comparison
  push: (lhs > rhs).uint.u256

op slt, FkFrontier, inline = true, lhs, rhs:
  ## 0x12, Signed less-than comparison
  push: (cast[Int256](lhs) < cast[Int256](rhs)).uint.u256

op sgt, FkFrontier, inline = true, lhs, rhs:
  ## 0x13, Signed greater-than comparison
  push: (cast[Int256](lhs) > cast[Int256](rhs)).uint.u256

op eq, FkFrontier, inline = true, lhs, rhs:
  ## 0x14, Signed greater-than comparison
  push: (lhs == rhs).uint.u256

op isZero, FkFrontier, inline = true, value:
  ## 0x15, Check if zero
  push: value.isZero.uint.u256

op andOp, FkFrontier, inline = true, lhs, rhs:
  ## 0x16, Bitwise AND
  push: lhs and rhs

op orOp, FkFrontier, inline = true, lhs, rhs:
  ## 0x17, Bitwise AND
  push: lhs or rhs

op xorOp, FkFrontier, inline = true, lhs, rhs:
  ## 0x18, Bitwise AND
  push: lhs xor rhs

op notOp, FkFrontier, inline = true, value:
  ## 0x19, Check if zero
  push: value.not

op byteOp, FkFrontier, inline = true, position, value:
  ## 0x20, Retrieve single byte from word.

  let pos = position.toInt

  push:
    if pos >= 32: zero(Uint256)
    else:
      when system.cpuEndian == bigEndian:
        cast[array[256, byte]](value)[pos].u256
      else:
        cast[array[256, byte]](value)[255 - pos].u256

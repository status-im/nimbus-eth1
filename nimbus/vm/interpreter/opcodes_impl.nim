# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stint, ./utils/[macros_procs_opcodes, utils_numeric],
  ./gas_meter, ./opcode_values

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

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strutils,
  eth_common/eth_types,
  helpers, ./impl_std_import

proc add*(computation: var BaseComputation) =
  # Addition
  let (left, right) = computation.stack.popInt(2)

  let res = left + right
  pushRes()

proc addmod*(computation: var BaseComputation) =
  # Modulo Addition
  let (left, right, modulus) = computation.stack.popInt(3)

  let res = if modulus.isZero: zero(Uint256) # EVM special casing of div by 0
            else: addmod(left, right, modulus)
  pushRes()

proc sub*(computation: var BaseComputation) =
  # Subtraction
  let (left, right) = computation.stack.popInt(2)

  let res = left - right
  pushRes()


proc modulo*(computation: var BaseComputation) =
  # Modulo
  let (value, modulus) = computation.stack.popInt(2)

  let res = if modulus.isZero: zero(Uint256) # EVM special casing of div by 0
            else: value mod modulus
  pushRes()

proc smod*(computation: var BaseComputation) =
  # Signed Modulo
  let (value, modulus) = computation.stack.popInt(2)

  let res = if modulus.isZero: zero(Uint256)
            else: pseudoSignedToUnsigned(
              unsignedToPseudoSigned(value) mod unsignedToPseudoSigned(modulus)
              )
  pushRes()

proc mul*(computation: var BaseComputation) =
  # Multiplication
  let (left, right) = computation.stack.popInt(2)

  let res = left * right
  pushRes()

proc mulmod*(computation: var BaseComputation) =
  #  Modulo Multiplication
  let (left, right, modulus) = computation.stack.popInt(3)

  let res = if modulus.isZero: zero(Uint256)
            else: mulmod(left, right, modulus)
  pushRes()

proc divide*(computation: var BaseComputation) =
  # Division
  let (numerator, denominator) = computation.stack.popInt(2)

  let res = if denominator.isZero: zero(Uint256)
            else: numerator div denominator
  pushRes()

proc sdiv*(computation: var BaseComputation) =
  # Signed Division
  let (value, divisor) = computation.stack.popInt(2)

  let res = if divisor.isZero: zero(Uint256)
            else: pseudoSignedToUnsigned(
              unsignedToPseudoSigned(value) div unsignedToPseudoSigned(divisor)
              )
  pushRes()

# no curry
proc exp*(computation: var BaseComputation) =

  # Exponentiation
  let (base, exponent) = computation.stack.popInt(2)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Exp].d_handler(exponent),
    reason="EXP: exponent bytes"
    )

  let res = if base.isZero: 0.u256 # 0^0 is 0 in py-evm
            else: base.pow(exponent)
  pushRes()

proc signextend*(computation: var BaseComputation) =
  # Signed Extend
  let (bits, value) = computation.stack.popInt(2)

  var res: UInt256
  if bits <= 31.u256:
    let testBit = bits.toInt * 8 + 7
    let bitPos = (1 shl testBit)
    let mask = u256(bitPos - 1)
    if not (value and bitPos).isZero:
      res = value or (not mask)
    else:
      res = value and mask
  else:
    res = value
  pushRes()

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Arithmetic and Logic Operators
## ===================================================
##

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ./oph_defs,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../constants,
    ../../stack,
    ../../v2computation,
    ../../v2types,
    ../gas_meter,
    ../utils/v2utils_numeric,
    ../v2gas_costs,
    chronicles,
    eth/common,
    options,
    sets

else:
  import macros

  # copied from stack.nim
  macro genTupleType(len: static[int], elemType: untyped): untyped =
    result = nnkTupleConstr.newNimNode()
    for i in 0 ..< len: result.add(elemType)

  # function stubs from stack.nim (to satisfy compiler logic)
  proc push[T](x: Stack; n: T) = discard
  proc popInt(x: var Stack): UInt256 = discard
  proc popInt(x: var Stack, n: static[int]): auto =
    var rc: genTupleType(n, UInt256)
    return rc

  # function stubs from v2utils_numeric.nim
  proc extractSign(v: var UInt256, sign: var bool) = discard
  proc setSign(v: var UInt256, sign: bool) =  discard
  func safeInt(x: Uint256): int = discard

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  addOp: Vm2OpFn = proc (k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      lhs + rhs

  mulOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      lhs * rhs

  subOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      lhs - rhs

  divideOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      if rhs == 0:
        # EVM special casing of div by 0
        zero(Uint256)
      else:
        lhs div rhs

  sdivOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    var r: UInt256
    if rhs != 0:
      var a = lhs
      var b = rhs
      var signA, signB: bool
      extractSign(a, signA)
      extractSign(b, signB)
      r = a div b
      setSign(r, signA xor signB)
    k.cpt.stack.push(r)

  moduloOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      if rhs == 0:
        zero(Uint256)
      else:
        lhs mod rhs

  smodOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    var r: UInt256
    if rhs != 0:
      var sign: bool
      var v = lhs
      var m = rhs
      extractSign(m, sign)
      extractSign(v, sign)
      r = v mod m
      setSign(r, sign)
    k.cpt.stack.push(r)

  addmodOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs, modulus) = k.cpt.stack.popInt(3)
    k.cpt.stack.push:
      if modulus == 0:
        zero(UInt256)
      else:
        addmod(lhs, rhs, modulus)

  mulmodOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs, modulus) = k.cpt.stack.popInt(3)
    k.cpt.stack.push:
      if modulus == 0:
        zero(UInt256)
      else:
        mulmod(lhs, rhs, modulus)

  expOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (base, exponent) = k.cpt.stack.popInt(2)
    when not breakCircularDependency:
      k.cpt.gasMeter.consumeGas(
        k.cpt.gasCosts[Exp].d_handler(exponent),
        reason = "EXP: exponent bytes")
    k.cpt.stack.push:
      if not base.isZero:
        base.pow(exponent)
      elif exponent.isZero:
        # https://github.com/ethereum/yellowpaper/issues/257
        # https://github.com/ethereum/tests/pull/460
        # https://github.com/ewasm/evm2wasm/issues/137
        1.u256
      else:
        zero(UInt256)

  signExtendOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (bits, value) = k.cpt.stack.popInt(2)
    var res: UInt256
    if bits <= 31.u256:
      let
        one = 1.u256
        testBit = bits.truncate(int) * 8 + 7
        bitPos = one shl testBit
        mask = bitPos - one
      if not isZero(value and bitPos):
        res = value or (not mask)
      else:
        res = value and mask
    else:
      res = value
    k.cpt.stack.push:
      res

  ltOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      (lhs < rhs).uint.u256

  gtOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      (lhs > rhs).uint.u256

  sltOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      (cast[Int256](lhs) < cast[Int256](rhs)).uint.u256

  sgtOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      (cast[Int256](lhs) > cast[Int256](rhs)).uint.u256

  eqOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      (lhs == rhs).uint.u256

  isZeroOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (value) = k.cpt.stack.popInt(1)
    k.cpt.stack.push:
      value.isZero.uint.u256

  andOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      lhs and rhs

  orOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      lhs or rhs

  xorOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (lhs, rhs) = k.cpt.stack.popInt(2)
    k.cpt.stack.push:
      lhs xor rhs

  notOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (value) = k.cpt.stack.popInt(1)
    k.cpt.stack.push:
      value.not

  byteOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (position, value) = k.cpt.stack.popInt(2)
    let pos = position.truncate(int)
    k.cpt.stack.push:
      if pos >= 32 or pos < 0:
        zero(Uint256)
      else:
        when system.cpuEndian == bigEndian:
          cast[array[32, byte]](value)[pos].u256
        else:
          cast[array[32, byte]](value)[31 - pos].u256

  # Constantinople's new opcodes

  shlOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (shift, num) = k.cpt.stack.popInt(2)
    let shiftLen = shift.safeInt
    if shiftLen >= 256:
      k.cpt.stack.push:
        0
    else:
      k.cpt.stack.push:
        num shl shiftLen

  shrOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let (shift, num) = k.cpt.stack.popInt(2)
    let shiftLen = shift.safeInt
    if shiftLen >= 256:
      k.cpt.stack.push:
        0
    else:
      # uint version of `shr`
      k.cpt.stack.push:
        num shr shiftLen

  sarOp: Vm2OpFn = proc(k: Vm2Ctx) =
    let shiftLen = k.cpt.stack.popInt().safeInt
    let num = cast[Int256](k.cpt.stack.popInt())
    if shiftLen >= 256:
      if num.isNegative:
        k.cpt.stack.push:
          cast[Uint256]((-1).i256)
      else:
       k.cpt.stack. push:
          0
    else:
      # int version of `shr` then force the result
      # into uint256
      k.cpt.stack.push:
        cast[Uint256](num shr shiftLen)

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecArithmetic*: seq[Vm2OpExec] = @[

    (opCode: Add,         ## 0x01, Addition
     forks: Vm2OpAllForks,
     info: "Addition operation",
     exec: (prep: vm2OpIgnore,
            run:  addOp,
            post: vm2OpIgnore)),

    (opCode: Mul,         ##  0x02, Multiplication
     forks: Vm2OpAllForks,
     info: "Multiplication operation",
     exec: (prep: vm2OpIgnore,
            run:  mulOp,
            post: vm2OpIgnore)),

    (opCode: Sub,         ## 0x03, Subtraction
     forks: Vm2OpAllForks,
     info: "Subtraction operation",
     exec: (prep: vm2OpIgnore,
            run:  subOp,
            post: vm2OpIgnore)),

    (opCode: Div,         ## 0x04, Division
     forks: Vm2OpAllForks,
     info: "Integer division operation",
     exec: (prep: vm2OpIgnore,
            run:  divideOp,
            post: vm2OpIgnore)),

    (opCode: Sdiv,        ## 0x05, Signed division
     forks: Vm2OpAllForks,
     info: "Signed integer division operation (truncated)",
     exec: (prep: vm2OpIgnore,
            run:  sdivOp,
            post: vm2OpIgnore)),

    (opCode: Mod,         ## 0x06, Modulo
     forks: Vm2OpAllForks,
     info: "Modulo remainder operation",
     exec: (prep: vm2OpIgnore,
            run:  moduloOp,
            post: vm2OpIgnore)),

    (opCode: Smod,        ## 0x07, Signed modulo
     forks: Vm2OpAllForks,
     info: "Signed modulo remainder operation",
     exec: (prep: vm2OpIgnore,
            run:  smodOp,
            post: vm2OpIgnore)),

    (opCode: AddMod,      ## 0x08, Modulo addition, Intermediate
                          ## computations do not roll over at 2^256
     forks: Vm2OpAllForks,
     info: "Modulo addition operation",
     exec: (prep: vm2OpIgnore,
            run:  addmodOp,
            post: vm2OpIgnore)),

    (opCode: MulMod,      ## 0x09, Modulo multiplication, Intermediate
                          ## computations do not roll over at 2^256
     forks: Vm2OpAllForks,
     info: "Modulo multiplication operation",
     exec: (prep: vm2OpIgnore,
            run:  mulmodOp,
            post: vm2OpIgnore)),

    (opCode: Exp,         ## 0x0a, Exponentiation
     forks: Vm2OpAllForks,
     info: "Exponentiation operation",
     exec: (prep: vm2OpIgnore,
            run:  expOp,
            post: vm2OpIgnore)),

    (opCode: SignExtend,  ## 0x0b, Extend 2's complemet length
     forks: Vm2OpAllForks,
     info: "Extend length of two’s complement signed integer",
     exec: (prep: vm2OpIgnore,
            run:  signExtendOp,
            post: vm2OpIgnore)),

    (opCode: Lt,          ## 0x10, Less-than
     forks: Vm2OpAllForks,
     info: "Less-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  ltOp,
            post: vm2OpIgnore)),

    (opCode: Gt,          ## 0x11, Greater-than
     forks: Vm2OpAllForks,
     info: "Greater-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  gtOp,
            post: vm2OpIgnore)),

    (opCode: Slt,         ## 0x12, Signed less-than
     forks: Vm2OpAllForks,
     info: "Signed less-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  sltOp,
            post: vm2OpIgnore)),

    (opCode: Sgt,         ## 0x13, Signed greater-than
     forks: Vm2OpAllForks,
     info: "Signed greater-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  sgtOp,
            post: vm2OpIgnore)),

    (opCode: Eq,          ## 0x14, Equality
     forks: Vm2OpAllForks,
     info: "Equality comparison",
     exec: (prep: vm2OpIgnore,
            run:  eqOp,
            post: vm2OpIgnore)),

    (opCode: IsZero,      ## 0x15, Not operator
     forks: Vm2OpAllForks,
     info: "Simple not operator (Note: real Yellow Paper description)",
     exec: (prep: vm2OpIgnore,
            run:  isZeroOp,
            post: vm2OpIgnore)),

    (opCode: And,         ## 0x16, AND
     forks: Vm2OpAllForks,
     info: "Bitwise AND operation",
     exec: (prep: vm2OpIgnore,
            run:  andOp,
            post: vm2OpIgnore)),

    (opCode: Or,          ## 0x17, OR
     forks: Vm2OpAllForks,
     info: "Bitwise OR operation",
     exec: (prep: vm2OpIgnore,
            run:  orOp,
            post: vm2OpIgnore)),

    (opCode: Xor,         ## 0x18, XOR
     forks: Vm2OpAllForks,
     info: "Bitwise XOR operation",
     exec: (prep: vm2OpIgnore,
            run:  xorOp,
            post: vm2OpIgnore)),

    (opCode: Not,         ## 0x19, NOT
     forks: Vm2OpAllForks,
     info: "Bitwise NOT operation",
     exec: (prep: vm2OpIgnore,
            run:  notOp,
            post: vm2OpIgnore)),

    (opCode: Byte,        ## 0x1a, Retrieve byte
     forks: Vm2OpAllForks,
     info: "Retrieve single byte from word",
     exec: (prep: vm2OpIgnore,
            run:  byteOp,
            post: vm2OpIgnore)),

    # Constantinople's new opcodes

    (opCode: Shl,         ## 0x1b, Shift left
     forks: Vm2OpConstantinopleAndLater,
     info: "Shift left",
     exec: (prep: vm2OpIgnore,
            run:  shlOp,
            post: vm2OpIgnore)),

    (opCode: Shr,         ## 0x1c, Shift right logical
     forks: Vm2OpConstantinopleAndLater,
     info: "Logical shift right",
     exec: (prep: vm2OpIgnore,
            run:  shrOp,
            post: vm2OpIgnore)),

    (opCode: Sar,         ## 0x1d, Shift right arithmetic
     forks: Vm2OpConstantinopleAndLater,
     info: "Arithmetic shift right",
     exec: (prep: vm2OpIgnore,
            run:  sarOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

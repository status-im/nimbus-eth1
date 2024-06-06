# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
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

{.push raises: [].}

import
  std/options,
  ../../../constants,
  ../../computation,
  ../../evm_errors,
  ../../stack,
  ../../types,
  ../op_codes,
  ../gas_costs,
  ../utils/utils_numeric,
  ./oph_defs,
  eth/common

func slt(x, y: UInt256): bool =
  type SignedWord = signedWordType(UInt256)
  let x_neg = cast[SignedWord](x.mostSignificantWord) < 0
  let y_neg = cast[SignedWord](y.mostSignificantWord) < 0
  if x_neg xor y_neg: x_neg else: x < y

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  addOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x01, Addition
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push(lhs + rhs)

  mulOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x02, Multiplication
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push(lhs * rhs)

  subOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x03, Substraction
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push(lhs - rhs)

  divideOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x04, Division
    let
      (lhs, rhs) = ? k.cpt.stack.popInt(2)
      value = if rhs.isZero:
                # EVM special casing of div by 0
                zero(UInt256)
              else:
                lhs div rhs

    k.cpt.stack.push value


  sdivOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x05, Signed division
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)

    var r: UInt256
    if rhs.isZero.not:
      var a = lhs
      var b = rhs
      var signA, signB: bool
      extractSign(a, signA)
      extractSign(b, signB)
      r = a div b
      setSign(r, signA xor signB)
    k.cpt.stack.push(r)


  moduloOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x06, Modulo
    let
      (lhs, rhs) = ? k.cpt.stack.popInt(2)
      value = if rhs.isZero:
                zero(UInt256)
              else:
                lhs mod rhs

    k.cpt.stack.push value


  smodOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x07, Signed modulo
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)

    var r: UInt256
    if rhs.isZero.not:
      var sign: bool
      var v = lhs
      var m = rhs
      extractSign(m, sign)
      extractSign(v, sign)
      r = v mod m
      setSign(r, sign)
    k.cpt.stack.push(r)


  addmodOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x08, Modulo addition
    ## Intermediate computations do not roll over at 2^256
    let
      (lhs, rhs, modulus) = ? k.cpt.stack.popInt(3)
      value = if modulus.isZero:
                zero(UInt256)
              else:
                addmod(lhs, rhs, modulus)

    k.cpt.stack.push value


  mulmodOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x09, Modulo multiplication
    ## Intermediate computations do not roll over at 2^256
    let
      (lhs, rhs, modulus) = ? k.cpt.stack.popInt(3)
      value = if modulus.isZero:
                zero(UInt256)
              else:
                mulmod(lhs, rhs, modulus)

    k.cpt.stack.push value


  expOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x0A, Exponentiation
    let (base, exponent) = ? k.cpt.stack.popInt(2)

    ? k.cpt.opcodeGastCost(Exp,
      k.cpt.gasCosts[Exp].d_handler(exponent),
      reason = "EXP: exponent bytes")

    let value = if not base.isZero:
                  base.pow(exponent)
                elif exponent.isZero:
                  # https://github.com/ethereum/yellowpaper/issues/257
                  # https://github.com/ethereum/tests/pull/460
                  # https://github.com/ewasm/evm2wasm/issues/137
                  1.u256
                else:
                  zero(UInt256)

    k.cpt.stack.push value


  signExtendOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x0B, Sign extend
    ## Extend length of two’s complement signed integer.
    let (bits, value) = ? k.cpt.stack.popInt(2)

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
    k.cpt.stack.push res


  ltOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x10, Less-than comparison
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push((lhs < rhs).uint.u256)

  gtOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x11, Greater-than comparison
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push((lhs > rhs).uint.u256)

  sltOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x12, Signed less-than comparison
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push(slt(lhs, rhs).uint.u256)

  sgtOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x13, Signed greater-than comparison
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    # Arguments are swapped and SLT is used.
    k.cpt.stack.push(slt(rhs, lhs).uint.u256)

  eqOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x14, Equality comparison
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push((lhs == rhs).uint.u256)

  isZeroOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x15, Check if zero
    let value = ? k.cpt.stack.popInt()
    k.cpt.stack.push(value.isZero.uint.u256)

  andOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x16, Bitwise AND
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push(lhs and rhs)

  orOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x17, Bitwise OR
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push(lhs or rhs)

  xorOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x18, Bitwise XOR
    let (lhs, rhs) = ? k.cpt.stack.popInt(2)
    k.cpt.stack.push(lhs xor rhs)

  notOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x19, Check if zero
    let value = ? k.cpt.stack.popInt()
    k.cpt.stack.push(value.not)

  byteOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    ## 0x20, Retrieve single byte from word.
    let
      (position, value) = ? k.cpt.stack.popInt(2)
      val = if position >= 32.u256:
              zero(UInt256)
            else:
              let pos = position.truncate(int)
              when system.cpuEndian == bigEndian:
                cast[array[32, byte]](value)[pos].u256
              else:
                cast[array[32, byte]](value)[31 - pos].u256

    k.cpt.stack.push val


  # Constantinople's new opcodes

  shlOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    let (shift, num) = ? k.cpt.stack.popInt(2)
    let shiftLen = shift.safeInt
    if shiftLen >= 256:
      k.cpt.stack.push 0
    else:
      k.cpt.stack.push(num shl shiftLen)

  shrOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    let (shift, num) = ? k.cpt.stack.popInt(2)
    let shiftLen = shift.safeInt
    if shiftLen >= 256:
      k.cpt.stack.push 0
    else:
      # uint version of `shr`
      k.cpt.stack.push(num shr shiftLen)

  sarOp: Vm2OpFn = proc(k: var Vm2Ctx): EvmResultVoid =
    let
      shiftLen = ? k.cpt.stack.popSafeInt()
      num256 = ? k.cpt.stack.popInt()
      num = cast[Int256](num256)

    if shiftLen >= 256:
      if num.isNegative:
        k.cpt.stack.push(cast[UInt256]((-1).i256))
      else:
        k.cpt.stack. push 0
    else:
      # int version of `shr` then force the result
      # into uint256
      k.cpt.stack.push(cast[UInt256](num shr shiftLen))

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecArithmetic*: seq[Vm2OpExec] = @[

    (opCode: Add,         ## 0x01, Addition
     forks: Vm2OpAllForks,
     name: "add",
     info: "Addition operation",
     exec: (prep: vm2OpIgnore,
            run:  addOp,
            post: vm2OpIgnore)),

    (opCode: Mul,         ##  0x02, Multiplication
     forks: Vm2OpAllForks,
     name: "mul",
     info: "Multiplication operation",
     exec: (prep: vm2OpIgnore,
            run:  mulOp,
            post: vm2OpIgnore)),

    (opCode: Sub,         ## 0x03, Subtraction
     forks: Vm2OpAllForks,
     name: "sub",
     info: "Subtraction operation",
     exec: (prep: vm2OpIgnore,
            run:  subOp,
            post: vm2OpIgnore)),

    (opCode: Div,         ## 0x04, Division
     forks: Vm2OpAllForks,
     name: "divide",
     info: "Integer division operation",
     exec: (prep: vm2OpIgnore,
            run:  divideOp,
            post: vm2OpIgnore)),

    (opCode: Sdiv,        ## 0x05, Signed division
     forks: Vm2OpAllForks,
     name: "sdiv",
     info: "Signed integer division operation (truncated)",
     exec: (prep: vm2OpIgnore,
            run:  sdivOp,
            post: vm2OpIgnore)),

    (opCode: Mod,         ## 0x06, Modulo
     forks: Vm2OpAllForks,
     name: "modulo",
     info: "Modulo remainder operation",
     exec: (prep: vm2OpIgnore,
            run:  moduloOp,
            post: vm2OpIgnore)),

    (opCode: Smod,        ## 0x07, Signed modulo
     forks: Vm2OpAllForks,
     name: "smod",
     info: "Signed modulo remainder operation",
     exec: (prep: vm2OpIgnore,
            run:  smodOp,
            post: vm2OpIgnore)),

    (opCode: Addmod,      ## 0x08, Modulo addition, Intermediate
                          ## computations do not roll over at 2^256
     forks: Vm2OpAllForks,
     name: "addmod",
     info: "Modulo addition operation",
     exec: (prep: vm2OpIgnore,
            run:  addmodOp,
            post: vm2OpIgnore)),

    (opCode: Mulmod,      ## 0x09, Modulo multiplication, Intermediate
                          ## computations do not roll over at 2^256
     forks: Vm2OpAllForks,
     name: "mulmod",
     info: "Modulo multiplication operation",
     exec: (prep: vm2OpIgnore,
            run:  mulmodOp,
            post: vm2OpIgnore)),

    (opCode: Exp,         ## 0x0a, Exponentiation
     forks: Vm2OpAllForks,
     name: "exp",
     info: "Exponentiation operation",
     exec: (prep: vm2OpIgnore,
            run:  expOp,
            post: vm2OpIgnore)),

    (opCode: SignExtend,  ## 0x0b, Extend 2's complemet length
     forks: Vm2OpAllForks,
     name: "signExtend",
     info: "Extend length of two’s complement signed integer",
     exec: (prep: vm2OpIgnore,
            run:  signExtendOp,
            post: vm2OpIgnore)),

    (opCode: Lt,          ## 0x10, Less-than
     forks: Vm2OpAllForks,
     name: "lt",
     info: "Less-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  ltOp,
            post: vm2OpIgnore)),

    (opCode: Gt,          ## 0x11, Greater-than
     forks: Vm2OpAllForks,
     name: "gt",
     info: "Greater-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  gtOp,
            post: vm2OpIgnore)),

    (opCode: Slt,         ## 0x12, Signed less-than
     forks: Vm2OpAllForks,
     name: "slt",
     info: "Signed less-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  sltOp,
            post: vm2OpIgnore)),

    (opCode: Sgt,         ## 0x13, Signed greater-than
     forks: Vm2OpAllForks,
     name: "sgt",
     info: "Signed greater-than comparison",
     exec: (prep: vm2OpIgnore,
            run:  sgtOp,
            post: vm2OpIgnore)),

    (opCode: Eq,          ## 0x14, Equality
     forks: Vm2OpAllForks,
     name: "eq",
     info: "Equality comparison",
     exec: (prep: vm2OpIgnore,
            run:  eqOp,
            post: vm2OpIgnore)),

    (opCode: IsZero,      ## 0x15, Not operator
     forks: Vm2OpAllForks,
     name: "isZero",
     info: "Simple not operator (Note: real Yellow Paper description)",
     exec: (prep: vm2OpIgnore,
            run:  isZeroOp,
            post: vm2OpIgnore)),

    (opCode: And,         ## 0x16, AND
     forks: Vm2OpAllForks,
     name: "andOp",
     info: "Bitwise AND operation",
     exec: (prep: vm2OpIgnore,
            run:  andOp,
            post: vm2OpIgnore)),

    (opCode: Or,          ## 0x17, OR
     forks: Vm2OpAllForks,
     name: "orOp",
     info: "Bitwise OR operation",
     exec: (prep: vm2OpIgnore,
            run:  orOp,
            post: vm2OpIgnore)),

    (opCode: Xor,         ## 0x18, XOR
     forks: Vm2OpAllForks,
     name: "xorOp",
     info: "Bitwise XOR operation",
     exec: (prep: vm2OpIgnore,
            run:  xorOp,
            post: vm2OpIgnore)),

    (opCode: Not,         ## 0x19, NOT
     forks: Vm2OpAllForks,
     name: "notOp",
     info: "Bitwise NOT operation",
     exec: (prep: vm2OpIgnore,
            run:  notOp,
            post: vm2OpIgnore)),

    (opCode: Byte,        ## 0x1a, Retrieve byte
     forks: Vm2OpAllForks,
     name: "byteOp",
     info: "Retrieve single byte from word",
     exec: (prep: vm2OpIgnore,
            run:  byteOp,
            post: vm2OpIgnore)),

    # Constantinople's new opcodes

    (opCode: Shl,         ## 0x1b, Shift left
     forks: Vm2OpConstantinopleAndLater,
     name: "shlOp",
     info: "Shift left",
     exec: (prep: vm2OpIgnore,
            run:  shlOp,
            post: vm2OpIgnore)),

    (opCode: Shr,         ## 0x1c, Shift right logical
     forks: Vm2OpConstantinopleAndLater,
     name: "shrOp",
     info: "Logical shift right",
     exec: (prep: vm2OpIgnore,
            run:  shrOp,
            post: vm2OpIgnore)),

    (opCode: Sar,         ## 0x1d, Shift right arithmetic
     forks: Vm2OpConstantinopleAndLater,
     name: "sarOp",
     info: "Arithmetic shift right",
     exec: (prep: vm2OpIgnore,
            run:  sarOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

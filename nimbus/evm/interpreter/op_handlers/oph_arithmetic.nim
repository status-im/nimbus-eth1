# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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

proc addOp (k: var VmCtx): EvmResultVoid =
  ## 0x01, Addition
  k.cpt.stack.binaryOp(`+`)

proc mulOp(k: var VmCtx): EvmResultVoid =
  ## 0x02, Multiplication
  k.cpt.stack.binaryOp(`*`)

proc subOp(k: var VmCtx): EvmResultVoid =
  ## 0x03, Substraction
  k.cpt.stack.binaryOp(`-`)

proc divideOp(k: var VmCtx): EvmResultVoid =
  ## 0x04, Division
  template div256(top, lhs, rhs) =
    if rhs.isZero:
      # EVM special casing of div by 0
      top = zero(UInt256)
    else:
      top = lhs div rhs

  k.cpt.stack.binaryWithTop(div256)

proc sdivOp(k: var VmCtx): EvmResultVoid =
  ## 0x05, Signed division
  template sdiv256(top, lhs, rhs) =
    if rhs.isZero.not:
      var signA, signB: bool
      extractSign(lhs, signA)
      extractSign(rhs, signB)
      top = lhs div rhs
      setSign(top, signA xor signB)

  k.cpt.stack.binaryWithTop(sdiv256)

proc moduloOp(k: var VmCtx): EvmResultVoid =
  ## 0x06, Modulo
  template mod256(top, lhs, rhs) =
    if rhs.isZero:
      top = zero(UInt256)
    else:
      top = lhs mod rhs

  k.cpt.stack.binaryWithTop(mod256)

proc smodOp(k: var VmCtx): EvmResultVoid =
  ## 0x07, Signed modulo
  template smod256(top, lhs, rhs) =
    if rhs.isZero.not:
      var sign: bool      
      extractSign(rhs, sign)
      extractSign(lhs, sign)
      top = lhs mod rhs
      setSign(top, sign)

  k.cpt.stack.binaryWithTop(smod256)

proc addmodOp(k: var VmCtx): EvmResultVoid =
  ## 0x08, Modulo addition
  ## Intermediate computations do not roll over at 2^256
  ? k.cpt.stack.lsCheck(3)
  let
    lhs = k.cpt.stack.lsPeekInt(^1)
    rhs = k.cpt.stack.lsPeekInt(^2)
    modulus = k.cpt.stack.lsPeekInt(^3)
    value = if modulus.isZero:
              zero(UInt256)
            else:
              addmod(lhs, rhs, modulus)

  k.cpt.stack.lsShrink(2)
  k.cpt.stack.lsTop value
  ok()

proc mulmodOp(k: var VmCtx): EvmResultVoid =
  ## 0x09, Modulo multiplication
  ## Intermediate computations do not roll over at 2^256
  ? k.cpt.stack.lsCheck(3)
  let
    lhs = k.cpt.stack.lsPeekInt(^1)
    rhs = k.cpt.stack.lsPeekInt(^2)
    modulus = k.cpt.stack.lsPeekInt(^3)
    value = if modulus.isZero:
              zero(UInt256)
            else:
              mulmod(lhs, rhs, modulus)

  k.cpt.stack.lsShrink(2)
  k.cpt.stack.lsTop value
  ok()

proc expOp(k: var VmCtx): EvmResultVoid =
  ## 0x0A, Exponentiation
  template exp256(top, base, exponent) =
    ? k.cpt.opcodeGasCost(Exp,
      k.cpt.gasCosts[Exp].d_handler(exponent),
      reason = "EXP: exponent bytes")

    if not base.isZero:
      top = base.pow(exponent)
    elif exponent.isZero:
      # https://github.com/ethereum/yellowpaper/issues/257
      # https://github.com/ethereum/tests/pull/460
      # https://github.com/ewasm/evm2wasm/issues/137
      top = 1.u256
    else:
      top = zero(UInt256)

  k.cpt.stack.binaryWithTop(exp256)

proc signExtendOp(k: var VmCtx): EvmResultVoid =
  ## 0x0B, Sign extend
  ## Extend length of two’s complement signed integer.
  template se256(top, bits, value) =
    const one = 1.u256
    if bits <= 31.u256:
      let        
        testBit = bits.truncate(int) * 8 + 7
        bitPos = one shl testBit
        mask = bitPos - one
      if not isZero(value and bitPos):
        top = value or (not mask)
      else:
        top = value and mask
    else:
      top = value

  k.cpt.stack.binaryWithTop(se256)

proc ltOp(k: var VmCtx): EvmResultVoid =
  ## 0x10, Less-than comparison
  template lt256(lhs, rhs): auto =
    (lhs < rhs).uint.u256
  k.cpt.stack.binaryOp(lt256)

proc gtOp(k: var VmCtx): EvmResultVoid =
  ## 0x11, Greater-than comparison
  template gt256(lhs, rhs): auto =
    (lhs > rhs).uint.u256
  k.cpt.stack.binaryOp(gt256)

proc sltOp(k: var VmCtx): EvmResultVoid =
  ## 0x12, Signed less-than comparison
  template slt256(lhs, rhs): auto =
    slt(lhs, rhs).uint.u256
  k.cpt.stack.binaryOp(slt256)

proc sgtOp(k: var VmCtx): EvmResultVoid =
  ## 0x13, Signed greater-than comparison
  # Arguments are swapped and SLT is used.
  template sgt256(lhs, rhs): auto =
    slt(rhs, lhs).uint.u256
  k.cpt.stack.binaryOp(sgt256)

proc eqOp(k: var VmCtx): EvmResultVoid =
  ## 0x14, Equality comparison
  template eq256(lhs, rhs): auto =
    (lhs == rhs).uint.u256
  k.cpt.stack.binaryOp(eq256)

proc isZeroOp(k: var VmCtx): EvmResultVoid =
  ## 0x15, Check if zero
  template zero256(value): auto =
    value.isZero.uint.u256
  k.cpt.stack.unaryOp(zero256)

proc andOp(k: var VmCtx): EvmResultVoid =
  ## 0x16, Bitwise AND
  k.cpt.stack.binaryOp(`and`)

proc orOp(k: var VmCtx): EvmResultVoid =
  ## 0x17, Bitwise OR
  k.cpt.stack.binaryOp(`or`)

proc xorOp(k: var VmCtx): EvmResultVoid =
  ## 0x18, Bitwise XOR
  k.cpt.stack.binaryOp(`xor`)

proc notOp(k: var VmCtx): EvmResultVoid =
  ## 0x19, Check if zero
  k.cpt.stack.unaryOp(`not`)

proc byteOp(k: var VmCtx): EvmResultVoid =
  ## 0x20, Retrieve single byte from word.
  template byte256(top, position, value) =
    if position >= 32.u256:
      top = zero(UInt256)
    else:
      let pos = position.truncate(int)
      when system.cpuEndian == bigEndian:
        top = cast[array[32, byte]](value)[pos].u256
      else:
        top = cast[array[32, byte]](value)[31 - pos].u256

  k.cpt.stack.binaryWithTop(byte256)

# Constantinople's new opcodes

proc shlOp(k: var VmCtx): EvmResultVoid =
  ## 0x1b, Shift left
  template shl256(top, lhs, num) =
    let shiftLen = lhs.safeInt
    if shiftLen >= 256:
      top = 0.u256
    else:
      top = num shl shiftLen

  k.cpt.stack.binaryWithTop(shl256)

proc shrOp(k: var VmCtx): EvmResultVoid =
  ## 0x1c, Shift right logical
  template shr256(top, lhs, num) =
    let shiftLen = lhs.safeInt
    if shiftLen >= 256:
      top = 0.u256
    else:
      # uint version of `shr`
      top = num shr shiftLen

  k.cpt.stack.binaryWithTop(shr256)

proc sarOp(k: var VmCtx): EvmResultVoid =
  ## 0x1d, Shift right arithmetic
  template sar256(top, lhs, num256) =
    let
      shiftLen = lhs.safeInt
      num = cast[Int256](num256)

    if shiftLen >= 256:
      if num.isNegative:
        top = cast[UInt256]((-1).i256)
      else:
        top = 0.u256
    else:
      # int version of `shr` then force the result
      # into uint256
      top = cast[UInt256](num shr shiftLen)

  k.cpt.stack.binaryWithTop(sar256)

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecArithmetic*: seq[VmOpExec] = @[

    (opCode: Add,         ## 0x01, Addition
     forks: VmOpAllForks,
     name: "add",
     info: "Addition operation",
     exec: VmOpFn addOp),


    (opCode: Mul,         ##  0x02, Multiplication
     forks: VmOpAllForks,
     name: "mul",
     info: "Multiplication operation",
     exec: mulOp),


    (opCode: Sub,         ## 0x03, Subtraction
     forks: VmOpAllForks,
     name: "sub",
     info: "Subtraction operation",
     exec: subOp),


    (opCode: Div,         ## 0x04, Division
     forks: VmOpAllForks,
     name: "divide",
     info: "Integer division operation",
     exec: divideOp),


    (opCode: Sdiv,        ## 0x05, Signed division
     forks: VmOpAllForks,
     name: "sdiv",
     info: "Signed integer division operation (truncated)",
     exec: sdivOp),


    (opCode: Mod,         ## 0x06, Modulo
     forks: VmOpAllForks,
     name: "modulo",
     info: "Modulo remainder operation",
     exec: moduloOp),


    (opCode: Smod,        ## 0x07, Signed modulo
     forks: VmOpAllForks,
     name: "smod",
     info: "Signed modulo remainder operation",
     exec: smodOp),


    (opCode: Addmod,      ## 0x08, Modulo addition, Intermediate
                          ## computations do not roll over at 2^256
     forks: VmOpAllForks,
     name: "addmod",
     info: "Modulo addition operation",
     exec: addmodOp),


    (opCode: Mulmod,      ## 0x09, Modulo multiplication, Intermediate
                          ## computations do not roll over at 2^256
     forks: VmOpAllForks,
     name: "mulmod",
     info: "Modulo multiplication operation",
     exec: mulmodOp),


    (opCode: Exp,         ## 0x0a, Exponentiation
     forks: VmOpAllForks,
     name: "exp",
     info: "Exponentiation operation",
     exec: expOp),


    (opCode: SignExtend,  ## 0x0b, Extend 2's complemet length
     forks: VmOpAllForks,
     name: "signExtend",
     info: "Extend length of two’s complement signed integer",
     exec: signExtendOp),


    (opCode: Lt,          ## 0x10, Less-than
     forks: VmOpAllForks,
     name: "lt",
     info: "Less-than comparison",
     exec: ltOp),


    (opCode: Gt,          ## 0x11, Greater-than
     forks: VmOpAllForks,
     name: "gt",
     info: "Greater-than comparison",
     exec: gtOp),


    (opCode: Slt,         ## 0x12, Signed less-than
     forks: VmOpAllForks,
     name: "slt",
     info: "Signed less-than comparison",
     exec: sltOp),


    (opCode: Sgt,         ## 0x13, Signed greater-than
     forks: VmOpAllForks,
     name: "sgt",
     info: "Signed greater-than comparison",
     exec: sgtOp),


    (opCode: Eq,          ## 0x14, Equality
     forks: VmOpAllForks,
     name: "eq",
     info: "Equality comparison",
     exec: eqOp),


    (opCode: IsZero,      ## 0x15, Not operator
     forks: VmOpAllForks,
     name: "isZero",
     info: "Simple not operator (Note: real Yellow Paper description)",
     exec: isZeroOp),


    (opCode: And,         ## 0x16, AND
     forks: VmOpAllForks,
     name: "andOp",
     info: "Bitwise AND operation",
     exec: andOp),


    (opCode: Or,          ## 0x17, OR
     forks: VmOpAllForks,
     name: "orOp",
     info: "Bitwise OR operation",
     exec: orOp),


    (opCode: Xor,         ## 0x18, XOR
     forks: VmOpAllForks,
     name: "xorOp",
     info: "Bitwise XOR operation",
     exec: xorOp),


    (opCode: Not,         ## 0x19, NOT
     forks: VmOpAllForks,
     name: "notOp",
     info: "Bitwise NOT operation",
     exec: notOp),


    (opCode: Byte,        ## 0x1a, Retrieve byte
     forks: VmOpAllForks,
     name: "byteOp",
     info: "Retrieve single byte from word",
     exec: byteOp),


    # Constantinople's new opcodes

    (opCode: Shl,         ## 0x1b, Shift left
     forks: VmOpConstantinopleAndLater,
     name: "shlOp",
     info: "Shift left",
     exec: shlOp),


    (opCode: Shr,         ## 0x1c, Shift right logical
     forks: VmOpConstantinopleAndLater,
     name: "shrOp",
     info: "Logical shift right",
     exec: shrOp),


    (opCode: Sar,         ## 0x1d, Shift right arithmetic
     forks: VmOpConstantinopleAndLater,
     name: "sarOp",
     info: "Arithmetic shift right",
     exec: sarOp)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

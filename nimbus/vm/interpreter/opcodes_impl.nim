# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stint, nimcrypto,
  ./utils/[macros_procs_opcodes, utils_numeric],
  ./gas_meter, ./gas_costs, ./opcode_values,
  ../memory, ../message, ../stack,
  ../../vm_state

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

op signExtend, FkFrontier, inline = false, bits, value:
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

# ##########################################
# 20s: SHA3

op sha3, FkFrontier, inline = true, startPos, length:
  ## 0x20, Compute Keccak-256 hash.
  let (pos, len) = (startPos.toInt, length.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Op.Sha3].m_handler(computation.memory.len, pos, len),
    reason="SHA3: word gas cost"
    )

  computation.memory.extend(pos, len)
  push:
    keccak256.digest computation.memory.bytes.toOpenArray(pos, pos+len)

# ##########################################
# 30s: Environmental Information

op address, FkFrontier, inline = true:
  ## 0x30, Get address of currently executing account.
  push: computation.msg.storageAddress

op balance, FkFrontier, inline = true:
  ## 0x31, Get balance of the given account.
  let address = computation.stack.popAddress
  # computation.vmState.db(readOnly=true):
  #   push: db.getBalance(address)
  push: zero(UInt256) # TODO: Stub

op origin, FkFrontier, inline = true:
  ## 0x32, Get execution origination address.
  push: computation.msg.origin

op caller, FkFrontier, inline = true:
  ## 0x33, Get caller address.
  push: computation.msg.origin

op callValue, FkFrontier, inline = true:
  ## 0x34, Get deposited value by the instruction/transaction
  ##       responsible for this execution
  push: computation.msg.value

op callDataLoad, FkFrontier, inline = false, startPos:
  ## 0x35, Get input data of current environment
  let start = startPos.toInt

  # If the data does not take 32 bytes, pad with zeros
  let lim = min(computation.msg.data.len, start + 32)
  let padding = start + 32 - lim
  var value: array[32, byte] # We rely on value being initialized with 0 by default
  value[padding ..< lim] = computation.msg.data.toOpenArray(start, start + lim)

  push: value # TODO, with the new implementation we can delete push for seq[byte]

op callDataSize, FkFrontier, inline = true:
  ## 0x36, Get size of input data in current environment.
  push: computation.msg.data.len.u256

op callDataCopy, FkFrontier, inline = false, memStartPos, copyStartPos, size:
  ## 0x37, Copy input data in current environment to memory.

  let (memPos, copyPos, len) = (memStartPos.toInt, copyStartPos.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CallDataCopy].m_handler(memPos, copyPos, len),
    reason="CallDataCopy fee")

  computation.memory.extend(memPos, len)

  # If the data does not take 32 bytes, pad with zeros
  let lim = min(computation.msg.data.len, copyPos + len)
  let padding = copyPos + len - lim
  # Note: when extending, extended memory is zero-ed, we only need to offset with padding value
  computation.memory.write(memPos):
    computation.msg.data.toOpenArray(copyPos+padding, copyPos+lim)

op codesize, FkFrontier, inline = true:
  ## 0x38, Get size of code running in current environment.
  push: computation.code.len

op codecopy, FkFrontier, inline = false, memStartPos, copyStartPos, size:
  ## 0x39, Copy code running in current environment to memory.

  let (memPos, copyPos, len) = (memStartPos.toInt, copyStartPos.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CodeCopy].m_handler(memPos, copyPos, len),
    reason="CodeCopy fee")

  computation.memory.extend(memPos, len)

  # TODO: here Py-EVM is doing something very complex, increasing a program counter in the "CodeStream" type.
  #       while Geth, Parity and the Yellow paper are just copying bytes?
  #   https://github.com/ethereum/py-evm/blob/090b29141d1d80c4b216cfa7ab889115df3c0da0/evm/vm/logic/context.py#L96-L97
  #   https://github.com/paritytech/parity/blob/98b7c07171cd320f32877dfa5aa528f585dc9a72/ethcore/evm/src/interpreter/mod.rs#L581-L582
  #   https://github.com/ethereum/go-ethereum/blob/947e0afeb3bce9c52548979daddd1e00aa0d7ba8/core/vm/instructions.go#L478-L479

  # If the data does not take 32 bytes, pad with zeros
  let lim = min(computation.code.bytes.len, copyPos + len)
  let padding = copyPos + len - lim
  # Note: when extending, extended memory is zero-ed, we only need to offset with padding value
  computation.memory.write(memPos):
    computation.code.bytes.toOpenArray(copyPos+padding, copyPos+lim)

op gasprice, FkFrontier, inline = true:
  # 0x3A, Get price of gas in current environment.
  push: computation.msg.gasPrice

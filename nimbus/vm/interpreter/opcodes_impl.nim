# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stint, nimcrypto, strformat, eth_common, times,
  ./utils/[macros_procs_opcodes, utils_numeric],
  ./gas_meter, ./gas_costs, ./opcode_values,
  ../memory, ../message, ../stack, ../code_stream,
  ../../vm_state, ../../errors,
  ../../db/[db_chain, state_db],
  ../../utils/bytes

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
  computation.vmState.db(readOnly=true):
    push: db.getBalance(address)

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
  ## 0x3A, Get price of gas in current environment.
  push: computation.msg.gasPrice

op extCodeSize, FkFrontier, inline = true:
  ## 0x3b, Get size of an account's code
  let account = computation.stack.popAddress()
  push: 0 # TODO

op extCodeCopy, FkFrontier, inline = true, memStartPos, copyStartPos, size:
  ## 0x3c, Copy an account's code to memory.
  let (memPos, copyPos, len) = (memStartPos.toInt, copyStartPos.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CodeCopy].m_handler(memPos, copyPos, len),
    reason="ExtCodeCopy fee")

  computation.memory.extend(memPos, len)

  # TODO implementation

op returnDataSize, FkFrontier, inline = true:
  ## 0x3d, Get size of output data from the previous call from the current environment.
  push: computation.returnData.len

op returnDataCopy, FkFrontier, inline = false,  memStartPos, copyStartPos, size:
  ## 0x3e, Copy output data from the previous call to memory.
  let (memPos, copyPos, len) = (memStartPos.toInt, copyStartPos.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CodeCopy].m_handler(memPos, copyPos, len),
    reason="ExtCodeCopy fee")

  if copyPos + len > computation.returnData.len:
    # TODO Geth additionally checks copyPos + len < 64
    #      Parity uses a saturating addition
    #      Yellow paper mentions  μs[1] + i are not subject to the 2^256 modulo.
    raise newException(OutOfBoundsRead,
      "Return data length is not sufficient to satisfy request.  Asked \n" &
      &"for data from index {copyStartPos} to {copyStartPos + size}. Return data is {computation.returnData.len} in \n" &
      "length")

  computation.memory.extend(memPos, len)

  computation.memory.write(memPos):
    computation.code.bytes.toOpenArray(copyPos, copyPos+len)

# ##########################################
# 40s: Block Information

op blockhash, FkFrontier, inline = true, blockNumber:
  ## 0x40, Get the hash of one of the 256 most recent complete blocks.
  push: computation.vmState.getAncestorHash(blockNumber)

op coinbase, FkFrontier, inline = true:
  ## 0x41, Get the block's beneficiary address.
  push: computation.vmState.coinbase

op timestamp, FkFrontier, inline = true:
  ## 0x42, Get the block's timestamp.
  push: computation.vmState.timestamp.toUnix

op blocknumber, FkFrontier, inline = true:
  ## 0x43, Get the block's number.
  push: computation.vmState.blockNumber

op difficulty, FkFrontier, inline = true:
  ## 0x44, Get the block's difficulty
  push: computation.vmState.difficulty

op gasLimit, FkFrontier, inline = true:
  ## 0x45, Get the block's gas limit
  push: computation.vmState.gasLimit

# ##########################################
# 50s: Stack, Memory, Storage and Flow Operations

op pop, FkFrontier, inline = true:
  ## 0x50, Remove item from stack.
  discard computation.stack.popInt()

op mload, FkFrontier, inline = true, memStartPos:
  ## 0x51, Load word from memory
  let memPos = memStartPos.toInt

  computation.gasMeter.consumeGas(
    computation.gasCosts[MLoad].m_handler(computation.memory.len, memPos, 32),
    reason="MLOAD: GasVeryLow + memory expansion"
    )
  computation.memory.extend(memPos, 32)

  push: computation.memory.read(memPos, 32) # TODO, should we convert to native endianness?

op mstore, FkFrontier, inline = true, memStartPos, value:
  ## 0x52, Save word to memory
  let memPos = memStartPos.toInt

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore].m_handler(computation.memory.len, memPos, 32),
    reason="MSTORE: GasVeryLow + memory expansion"
    )

  computation.memory.extend(memPos, 32)
  computation.memory.write(memPos, value.toByteArrayBE) # is big-endian correct? Parity/Geth do convert

op mstore8, FkFrontier, inline = true, memStartPos, value:
  ## 0x53, Save byte to memory
  let memPos = memStartPos.toInt

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore].m_handler(computation.memory.len, memPos, 1),
    reason="MSTORE8: GasVeryLow + memory expansion"
    )

  computation.memory.extend(memPos, 1)
  computation.memory.write(memPos, [value.toByteArrayBE[0]])

op sload, FkFrontier, inline = true, slot:
  ## 0x54, Load word from storage.

  computation.vmState.db(readOnly=true):
    let (value, _) = db.getStorage(computation.msg.storageAddress, slot)
    push: value

op sstore, FkFrontier, inline = false, slot, value:
  ## 0x55, Save word to storage.

  var currentValue = 0.u256
  var existing = false

  computation.vmState.db(readOnly=true):
    (currentValue, existing) = db.getStorage(computation.msg.storageAddress, slot)

  let
    gasParam = GasParams(kind: Op.Sstore, s_isStorageEmpty: not existing)
    (gasCost, gasRefund) = computation.gasCosts[Sstore].c_handler(currentValue, gasParam)

  computation.gasMeter.consumeGas(gasCost, &"SSTORE: {computation.msg.storageAddress}[slot] -> {value} ({currentValue})")

  if gasRefund > 0:
    computation.gasMeter.refundGas(gasRefund)

  computation.vmState.db(readOnly=false):
    db.setStorage(computation.msg.storageAddress, slot, value)

op jump, FkFrontier, inline = true, jumpTarget:
  ## 0x56, Alter the program counter

  let jt = jumpTarget.toInt
  computation.code.pc = jt

  let nextOpcode = computation.code.peek
  if nextOpcode != JUMPDEST:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")
  # TODO: next check seems redundant
  if not computation.code.isValidOpcode(jt):
    raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

  # TODO: what happens if there is an error, rollback?

op jumpI, FkFrontier, inline = true, jumpTarget, testedValue:
  ## 0x57, Conditionally alter the program counter.

  if testedValue != 0:
    let jt = jumpTarget.toInt
    computation.code.pc = jt

    let nextOpcode = computation.code.peek
    if nextOpcode != JUMPDEST:
      raise newException(InvalidJumpDestination, "Invalid Jump Destination")
    # TODO: next check seems redundant
    if not computation.code.isValidOpcode(jt):
      raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

op pc, FkFrontier, inline = true:
  ## 0x58, Get the value of the program counter prior to the increment corresponding to this instruction.
  push: max(computation.code.pc - 1, 0)

op msize, FkFrontier, inline = true:
  ## 0x59, Get the size of active memory in bytes.
  push: computation.memory.len

op gas, FkFrontier, inline = true:
  ## 0x5a, Get the amount of available gas, including the corresponding reduction for the cost of this instruction.
  push: computation.gasMeter.gasRemaining

op jumpDest, FkFrontier, inline = true:
  ## 0x5b, Mark a valid destination for jumps. This operation has no effect on machine state during execution.
  discard

genPushFkFrontier()

# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, times, sets, sequtils, options,
  chronicles, stint, nimcrypto, stew/ranges/[ptr_arith], eth/common,
  ./utils/[macros_procs_opcodes, utils_numeric],
  ./gas_meter, ./gas_costs, ./opcode_values, ./vm_forks,
  ../memory, ../stack, ../code_stream, ../computation,
  ../../vm_state, ../../errors, ../../constants, ../../vm_types,
  ../../db/[db_chain, accounts_cache]

when defined(evmc_enabled):
  import  ../evmc_api, ../evmc_helpers, evmc/evmc

logScope:
  topics = "opcode impl"

# ##################################
# Syntactic sugar

template push(x: typed) {.dirty.} =
  ## Push an expression on the computation stack
  c.stack.push x

# ##################################
# 0s: Stop and Arithmetic Operations

op add, inline = true, lhs, rhs:
  ## 0x01, Addition
  push: lhs + rhs

op mul, inline = true, lhs, rhs:
  ## 0x02, Multiplication
  push: lhs * rhs

op sub, inline = true, lhs, rhs:
  ## 0x03, Substraction
  push: lhs - rhs

op divide, inline = true, lhs, rhs:
  ## 0x04, Division
  push:
    if rhs == 0: zero(Uint256) # EVM special casing of div by 0
    else:        lhs div rhs

op sdiv, inline = true, lhs, rhs:
  ## 0x05, Signed division
  var r: UInt256
  if rhs != 0:
    var a = lhs
    var b = rhs
    var signA, signB: bool
    extractSign(a, signA)
    extractSign(b, signB)
    r = a div b
    setSign(r, signA xor signB)
  push(r)

op modulo, inline = true, lhs, rhs:
  ## 0x06, Modulo
  push:
    if rhs == 0: zero(Uint256)
    else:        lhs mod rhs

op smod, inline = true, lhs, rhs:
  ## 0x07, Signed modulo
  var r: UInt256
  if rhs != 0:
    var sign: bool
    var v = lhs
    var m = rhs
    extractSign(m, sign)
    extractSign(v, sign)
    r = v mod m
    setSign(r, sign)

  push(r)

op addmod, inline = true, lhs, rhs, modulus:
  ## 0x08, Modulo addition
  ## Intermediate computations do not roll over at 2^256
  push:
    if modulus == 0: zero(UInt256) # EVM special casing of div by 0
    else: addmod(lhs, rhs, modulus)

op mulmod, inline = true, lhs, rhs, modulus:
  ## 0x09, Modulo multiplication
  ## Intermediate computations do not roll over at 2^256
  push:
    if modulus == 0: zero(UInt256) # EVM special casing of div by 0
    else: mulmod(lhs, rhs, modulus)

op exp, inline = true, base, exponent:
  ## 0x0A, Exponentiation
  c.gasMeter.consumeGas(
    c.gasCosts[Exp].d_handler(exponent),
    reason="EXP: exponent bytes"
    )
  push:
    if base.isZero:
      if exponent.isZero:
        # https://github.com/ethereum/yellowpaper/issues/257
        # https://github.com/ethereum/tests/pull/460
        # https://github.com/ewasm/evm2wasm/issues/137
        1.u256
      else:
        zero(UInt256)
    else:
      base.pow(exponent)

op signExtend, inline = false, bits, value:
  ## 0x0B, Sign extend
  ## Extend length of two’s complement signed integer.

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

  push: res

# ##########################################
# 10s: Comparison & Bitwise Logic Operations

op lt, inline = true, lhs, rhs:
  ## 0x10, Less-than comparison
  push: (lhs < rhs).uint.u256

op gt, inline = true, lhs, rhs:
  ## 0x11, Greater-than comparison
  push: (lhs > rhs).uint.u256

op slt, inline = true, lhs, rhs:
  ## 0x12, Signed less-than comparison
  push: (cast[Int256](lhs) < cast[Int256](rhs)).uint.u256

op sgt, inline = true, lhs, rhs:
  ## 0x13, Signed greater-than comparison
  push: (cast[Int256](lhs) > cast[Int256](rhs)).uint.u256

op eq, inline = true, lhs, rhs:
  ## 0x14, Signed greater-than comparison
  push: (lhs == rhs).uint.u256

op isZero, inline = true, value:
  ## 0x15, Check if zero
  push: value.isZero.uint.u256

op andOp, inline = true, lhs, rhs:
  ## 0x16, Bitwise AND
  push: lhs and rhs

op orOp, inline = true, lhs, rhs:
  ## 0x17, Bitwise AND
  push: lhs or rhs

op xorOp, inline = true, lhs, rhs:
  ## 0x18, Bitwise AND
  push: lhs xor rhs

op notOp, inline = true, value:
  ## 0x19, Check if zero
  push: value.not

op byteOp, inline = true, position, value:
  ## 0x20, Retrieve single byte from word.

  let pos = position.truncate(int)

  push:
    if pos >= 32 or pos < 0: zero(Uint256)
    else:
      when system.cpuEndian == bigEndian:
        cast[array[32, byte]](value)[pos].u256
      else:
        cast[array[32, byte]](value)[31 - pos].u256

# ##########################################
# 20s: SHA3

op sha3, inline = true, startPos, length:
  ## 0x20, Compute Keccak-256 hash.
  let (pos, len) = (startPos.safeInt, length.safeInt)

  if pos < 0 or len < 0 or pos > 2147483648:
    raise newException(OutOfBoundsRead, "Out of bounds memory access")

  c.gasMeter.consumeGas(
    c.gasCosts[Op.Sha3].m_handler(c.memory.len, pos, len),
    reason="SHA3: word gas cost"
    )

  c.memory.extend(pos, len)
  let endRange = min(pos + len, c.memory.len) - 1
  if endRange == -1 or pos >= c.memory.len:
    push(EMPTY_SHA3)
  else:
    push:
      keccak256.digest c.memory.bytes.toOpenArray(pos, endRange)

# ##########################################
# 30s: Environmental Information

proc writePaddedResult(mem: var Memory,
                       data: openarray[byte],
                       memPos, dataPos, len: Natural,
                       paddingValue = 0.byte) =

  mem.extend(memPos, len)
  let dataEndPosition = dataPos.int64 + len - 1
  let sourceBytes = data[min(dataPos, data.len) .. min(data.len - 1, dataEndPosition)]
  mem.write(memPos, sourceBytes)

  # Don't duplicate zero-padding of mem.extend
  let paddingOffset = min(memPos + sourceBytes.len, mem.len)
  let numPaddingBytes = min(mem.len - paddingOffset, len - sourceBytes.len)
  if numPaddingBytes > 0:
    # TODO: avoid unnecessary memory allocation
    mem.write(paddingOffset, repeat(paddingValue, numPaddingBytes))

op address, inline = true:
  ## 0x30, Get address of currently executing account.
  push: c.msg.contractAddress

op balance, inline = true:
  ## 0x31, Get balance of the given account.
  let address = c.stack.popAddress()
  push: c.getBalance(address)

op origin, inline = true:
  ## 0x32, Get execution origination address.
  push: c.getOrigin()

op caller, inline = true:
  ## 0x33, Get caller address.
  push: c.msg.sender

op callValue, inline = true:
  ## 0x34, Get deposited value by the instruction/transaction
  ##       responsible for this execution
  push: c.msg.value

op callDataLoad, inline = false, startPos:
  ## 0x35, Get input data of current environment
  let start = startPos.cleanMemRef
  if start >= c.msg.data.len:
    push: 0
    return

  # If the data does not take 32 bytes, pad with zeros
  let endRange = min(c.msg.data.len - 1, start + 31)
  let presentBytes = endRange - start
  # We rely on value being initialized with 0 by default
  var value: array[32, byte]
  value[0 .. presentBytes] = c.msg.data.toOpenArray(start, endRange)

  push: value

op callDataSize, inline = true:
  ## 0x36, Get size of input data in current environment.
  push: c.msg.data.len.u256

op callDataCopy, inline = false, memStartPos, copyStartPos, size:
  ## 0x37, Copy input data in current environment to memory.
  # TODO tests: https://github.com/status-im/nimbus/issues/67

  let (memPos, copyPos, len) = (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)

  c.gasMeter.consumeGas(
    c.gasCosts[CallDataCopy].m_handler(c.memory.len, memPos, len),
    reason="CallDataCopy fee")

  c.memory.writePaddedResult(c.msg.data, memPos, copyPos, len)

op codeSize, inline = true:
  ## 0x38, Get size of code running in current environment.
  push: c.code.len

op codeCopy, inline = false, memStartPos, copyStartPos, size:
  ## 0x39, Copy code running in current environment to memory.
  # TODO tests: https://github.com/status-im/nimbus/issues/67

  let (memPos, copyPos, len) = (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)

  c.gasMeter.consumeGas(
    c.gasCosts[CodeCopy].m_handler(c.memory.len, memPos, len),
    reason="CodeCopy fee")

  c.memory.writePaddedResult(c.code.bytes, memPos, copyPos, len)

op gasprice, inline = true:
  ## 0x3A, Get price of gas in current environment.
  push: c.getGasPrice()

op extCodeSize, inline = true:
  ## 0x3b, Get size of an account's code
  let address = c.stack.popAddress()
  push: c.getCodeSize(address)

op extCodeCopy, inline = true:
  ## 0x3c, Copy an account's code to memory.
  let address = c.stack.popAddress()
  let (memStartPos, codeStartPos, size) = c.stack.popInt(3)
  let (memPos, codePos, len) = (memStartPos.cleanMemRef, codeStartPos.cleanMemRef, size.cleanMemRef)

  c.gasMeter.consumeGas(
    c.gasCosts[ExtCodeCopy].m_handler(c.memory.len, memPos, len),
    reason="ExtCodeCopy fee")

  let codeBytes = c.getCode(address)
  c.memory.writePaddedResult(codeBytes, memPos, codePos, len)

op returnDataSize, inline = true:
  ## 0x3d, Get size of output data from the previous call from the current environment.
  push: c.returnData.len

op returnDataCopy, inline = false,  memStartPos, copyStartPos, size:
  ## 0x3e, Copy output data from the previous call to memory.
  let (memPos, copyPos, len) = (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)
  let gasCost = c.gasCosts[ReturnDataCopy].m_handler(c.memory.len, memPos, len)
  c.gasMeter.consumeGas(
    gasCost,
    reason="returnDataCopy fee")

  if copyPos + len > c.returnData.len:
    # TODO Geth additionally checks copyPos + len < 64
    #      Parity uses a saturating addition
    #      Yellow paper mentions  μs[1] + i are not subject to the 2^256 modulo.
    raise newException(OutOfBoundsRead,
      "Return data length is not sufficient to satisfy request.  Asked \n" &
      &"for data from index {copyStartPos} to {copyStartPos + size}. Return data is {c.returnData.len} in \n" &
      "length")

  c.memory.writePaddedResult(c.returnData, memPos, copyPos, len)

# ##########################################
# 40s: Block Information

op blockhash, inline = true, blockNumber:
  ## 0x40, Get the hash of one of the 256 most recent complete blocks.
  push: c.getBlockHash(blockNumber)

op coinbase, inline = true:
  ## 0x41, Get the block's beneficiary address.
  push: c.getCoinbase()

op timestamp, inline = true:
  ## 0x42, Get the block's timestamp.
  push: c.getTimestamp()

op blocknumber, inline = true:
  ## 0x43, Get the block's number.
  push: c.getBlockNumber()

op difficulty, inline = true:
  ## 0x44, Get the block's difficulty
  push: c.getDifficulty()

op gasLimit, inline = true:
  ## 0x45, Get the block's gas limit
  push: c.getGasLimit()

op chainId, inline = true:
  ## 0x46, Get current chain’s EIP-155 unique identifier.
  push: c.getChainId()

op selfBalance, inline = true:
  ## 0x47, Get current contract's balance.
  push: c.getBalance(c.msg.contractAddress)

# ##########################################
# 50s: Stack, Memory, Storage and Flow Operations

op pop, inline = true:
  ## 0x50, Remove item from stack.
  discard c.stack.popInt()

op mload, inline = true, memStartPos:
  ## 0x51, Load word from memory
  let memPos = memStartPos.cleanMemRef

  c.gasMeter.consumeGas(
    c.gasCosts[MLoad].m_handler(c.memory.len, memPos, 32),
    reason="MLOAD: GasVeryLow + memory expansion"
    )
  c.memory.extend(memPos, 32)

  push: c.memory.read(memPos, 32) # TODO, should we convert to native endianness?

op mstore, inline = true, memStartPos, value:
  ## 0x52, Save word to memory
  let memPos = memStartPos.cleanMemRef

  c.gasMeter.consumeGas(
    c.gasCosts[MStore].m_handler(c.memory.len, memPos, 32),
    reason="MSTORE: GasVeryLow + memory expansion"
    )

  c.memory.extend(memPos, 32)
  c.memory.write(memPos, value.toByteArrayBE) # is big-endian correct? Parity/Geth do convert

op mstore8, inline = true, memStartPos, value:
  ## 0x53, Save byte to memory
  let memPos = memStartPos.cleanMemRef

  c.gasMeter.consumeGas(
    c.gasCosts[MStore].m_handler(c.memory.len, memPos, 1),
    reason="MSTORE8: GasVeryLow + memory expansion"
    )

  c.memory.extend(memPos, 1)
  c.memory.write(memPos, [value.toByteArrayBE[31]])

op sload, inline = true, slot:
  ## 0x54, Load word from storage.
  push: c.getStorage(slot)

when not evmc_enabled:
  template sstoreImpl(c: Computation, slot, newValue: Uint256) =
    let currentValue {.inject.} = c.getStorage(slot)

    let
      gasParam = GasParams(kind: Op.Sstore, s_currentValue: currentValue)
      (gasCost, gasRefund) = c.gasCosts[Sstore].c_handler(newValue, gasParam)

    c.gasMeter.consumeGas(gasCost, &"SSTORE: {c.msg.contractAddress}[{slot}] -> {newValue} ({currentValue})")

    if gasRefund > 0:
      c.gasMeter.refundGas(gasRefund)

    c.vmState.mutateStateDB:
      db.setStorage(c.msg.contractAddress, slot, newValue)

when evmc_enabled:
  template sstoreEvmc(c: Computation, slot, newValue: Uint256) =
    let
      status   = c.host.setStorage(c.msg.contractAddress, slot, newValue)
      gasParam = GasParams(kind: Op.Sstore, s_status: status)
      gasCost  = c.gasCosts[Sstore].c_handler(newValue, gasParam)[0]

    c.gasMeter.consumeGas(gasCost, &"SSTORE: {c.msg.contractAddress}[{slot}] -> {newValue}")

op sstore, inline = false, slot, newValue:
  ## 0x55, Save word to storage.
  checkInStaticContext(c)

  when evmc_enabled:
    sstoreEvmc(c, slot, newValue)
  else:
    sstoreImpl(c, slot, newValue)

when not evmc_enabled:
  template sstoreNetGasMeteringImpl(c: Computation, slot, newValue: Uint256) =
    let stateDB = c.vmState.readOnlyStateDB
    let currentValue {.inject.} = c.getStorage(slot)

    let
      gasParam = GasParams(kind: Op.Sstore,
        s_currentValue: currentValue,
        s_originalValue: stateDB.getCommittedStorage(c.msg.contractAddress, slot)
      )
      (gasCost, gasRefund) = c.gasCosts[Sstore].c_handler(newValue, gasParam)

    c.gasMeter.consumeGas(gasCost, &"SSTORE EIP2200: {c.msg.contractAddress}[{slot}] -> {newValue} ({currentValue})")

    if gasRefund != 0:
      c.gasMeter.refundGas(gasRefund)

    c.vmState.mutateStateDB:
      db.setStorage(c.msg.contractAddress, slot, newValue)

op sstoreEIP2200, inline = false, slot, newValue:
  checkInStaticContext(c)
  const SentryGasEIP2200 = 2300  # Minimum gas required to be present for an SSTORE call, not consumed

  if c.gasMeter.gasRemaining <= SentryGasEIP2200:
    raise newException(OutOfGas, "Gas not enough to perform EIP2200 SSTORE")

  when evmc_enabled:
    sstoreEvmc(c, slot, newValue)
  else:
    sstoreNetGasMeteringImpl(c, slot, newValue)

op sstoreEIP1283, inline = false, slot, newValue:
  checkInStaticContext(c)

  when evmc_enabled:
    sstoreEvmc(c, slot, newValue)
  else:
    sstoreNetGasMeteringImpl(c, slot, newValue)

proc jumpImpl(c: Computation, jumpTarget: UInt256) =
  if jumpTarget >= c.code.len.u256:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")

  let jt = jumpTarget.truncate(int)
  c.code.pc = jt

  let nextOpcode = c.code.peek
  if nextOpcode != JUMPDEST:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")
  # TODO: next check seems redundant
  if not c.code.isValidOpcode(jt):
    raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

op jump, inline = true, jumpTarget:
  ## 0x56, Alter the program counter
  jumpImpl(c, jumpTarget)

op jumpI, inline = true, jumpTarget, testedValue:
  ## 0x57, Conditionally alter the program counter.
  if testedValue != 0:
    jumpImpl(c, jumpTarget)

op pc, inline = true:
  ## 0x58, Get the value of the program counter prior to the increment corresponding to this instruction.
  push: max(c.code.pc - 1, 0)

op msize, inline = true:
  ## 0x59, Get the size of active memory in bytes.
  push: c.memory.len

op gas, inline = true:
  ## 0x5a, Get the amount of available gas, including the corresponding reduction for the cost of this instruction.
  push: c.gasMeter.gasRemaining

op jumpDest, inline = true:
  ## 0x5b, Mark a valid destination for jumps. This operation has no effect on machine state during execution.
  discard

op beginSub, inline = true:
  ## 0x5c, Marks the entry point to a subroutine
  raise newException(OutOfGas, "Abort: Attempt to execute BeginSub opcode")

op returnSub, inline = true:
  ## 0x5d, Returns control to the caller of a subroutine.
  if c.returnStack.len == 0:
    raise newException(OutOfGas, "Abort: invalid returnStack during ReturnSub")
  # Other than the check that the return stack is not empty, there is no
  # need to validate the pc from 'returns', since we only ever push valid
  # values onto it via jumpsub.
  c.code.pc = c.returnStack.pop()

op jumpSub, inline = true, jumpTarget:
  ## 0x5e, Transfers control to a subroutine.
  if jumpTarget >= c.code.len.u256:
    raise newException(InvalidJumpDestination, "JumpSub destination exceeds code len")

  let returnPC = c.code.pc
  let jt = jumpTarget.truncate(int)
  c.code.pc = jt

  let nextOpcode = c.code.peek
  if nextOpcode != BeginSub:
    raise newException(InvalidJumpDestination, "Invalid JumpSub destination")

  if c.returnStack.len == 1023:
    raise newException(FullStack, "Out of returnStack")

  c.returnStack.add returnPC
  inc c.code.pc

# ##########################################
# 60s & 70s: Push Operations.
# 80s: Duplication Operations
# 90s: Exchange Operations
# a0s: Logging Operations

genPush()
genDup()
genSwap()
genLog()

# ##########################################
# f0s: System operations.
template genCreate(callName: untyped, opCode: Op): untyped =
  op callName, inline = false:
    checkInStaticContext(c)
    let
      endowment = c.stack.popInt()
      memPos = c.stack.popInt().safeInt

    when opCode == Create:
      const callKind = evmcCreate
      let memLen {.inject.} = c.stack.peekInt().safeInt
      let salt = 0.u256
    else:
      const callKind = evmcCreate2
      let memLen {.inject.} = c.stack.popInt().safeInt
      let salt = c.stack.peekInt()

    c.stack.top(0)

    let gasParams = GasParams(kind: Create,
      cr_currentMemSize: c.memory.len,
      cr_memOffset: memPos,
      cr_memLength: memLen
    )
    var gasCost = c.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
    when opCode == Create2:
      gasCost = gasCost + c.gasCosts[Create2].m_handler(0, 0, memLen)

    let reason = &"CREATE: GasCreate + {memLen} * memory expansion"
    c.gasMeter.consumeGas(gasCost, reason = reason)
    c.memory.extend(memPos, memLen)
    c.returnData.setLen(0)

    if c.msg.depth >= MaxCallDepth:
      debug "Computation Failure", reason = "Stack too deep", maxDepth = MaxCallDepth, depth = c.msg.depth
      return

    if endowment != 0:
      let senderBalance = c.getBalance(c.msg.contractAddress)
      if senderBalance < endowment:
        debug "Computation Failure", reason = "Insufficient funds available to transfer", required = endowment, balance = senderBalance
        return

    var createMsgGas = c.gasMeter.gasRemaining
    if c.fork >= FkTangerine:
      createMsgGas -= createMsgGas div 64
    c.gasMeter.consumeGas(createMsgGas, reason="CREATE")

    when evmc_enabled:
      let msg = nimbus_message(
        kind: callKind.evmc_call_kind,
        depth: (c.msg.depth + 1).int32,
        gas: createMsgGas,
        sender: c.msg.contractAddress,
        input_data: c.memory.readPtr(memPos),
        input_size: memLen.uint,
        value: toEvmc(endowment),
        create2_salt: toEvmc(salt)
      )

      var res = c.host.call(msg)
      c.returnData = @(makeOpenArray(res.outputData, res.outputSize.int))
      c.gasMeter.returnGas(res.gas_left)

      if res.status_code == EVMC_SUCCESS:
        c.stack.top(res.create_address)

      # TODO: a good candidate for destructor
      if not res.release.isNil:
        res.release(res)
    else:
      let childMsg = Message(
        kind: callKind,
        depth: c.msg.depth + 1,
        gas: createMsgGas,
        sender: c.msg.contractAddress,
        value: endowment,
        data: c.memory.read(memPos, memLen)
        )

      var child = newComputation(c.vmState, childMsg, salt)
      child.execCreate()
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top child.msg.contractAddress
      else:
        c.returnData = child.output

genCreate(create, Create)
genCreate(create2, Create2)

proc callParams(c: Computation): (UInt256, UInt256, EthAddress, EthAddress, CallKind, int, int, int, int, MsgFlags) =
  let gas = c.stack.popInt()
  let destination = c.stack.popAddress()
  let value = c.stack.popInt()

  result = (gas,
    value,
    destination,
    c.msg.contractAddress, # sender
    evmcCall,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.msg.flags)

proc callCodeParams(c: Computation): (UInt256, UInt256, EthAddress, EthAddress, CallKind, int, int, int, int, MsgFlags) =
  let gas = c.stack.popInt()
  let destination = c.stack.popAddress()
  let value = c.stack.popInt()

  result = (gas,
    value,
    destination,
    c.msg.contractAddress, # sender
    evmcCallCode,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.msg.flags)

proc delegateCallParams(c: Computation): (UInt256, UInt256, EthAddress, EthAddress, CallKind, int, int, int, int, MsgFlags) =
  let gas = c.stack.popInt()
  let destination = c.stack.popAddress()

  result = (gas,
    c.msg.value, # value
    destination,
    c.msg.sender, # sender
    evmcDelegateCall,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.msg.flags)

proc staticCallParams(c: Computation): (UInt256, UInt256, EthAddress, EthAddress, CallKind, int, int, int, int, MsgFlags) =
  let gas = c.stack.popInt()
  let destination = c.stack.popAddress()

  result = (gas,
    0.u256, # value
    destination,
    c.msg.contractAddress, # sender
    evmcCall,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    c.stack.popInt().cleanMemRef,
    emvcStatic) # is_static

template genCall(callName: untyped, opCode: Op): untyped =
  op callName, inline = false:
    ## CALL, 0xf1, Message-Call into an account
    ## CALLCODE, 0xf2, Message-call into this account with an alternative account's code.
    ## DELEGATECALL, 0xf4, Message-call into this account with an alternative account's code, but persisting the current values for sender and value.
    ## STATICCALL, 0xfa, Static message-call into an account.
    when opCode == Call:
      if emvcStatic == c.msg.flags and c.stack[^3, Uint256] > 0.u256:
        raise newException(StaticContextError, "Cannot modify state while inside of a STATICCALL context")

    let (gas, value, destination, sender, callKind,
         memInPos, memInLen, memOutPos, memOutLen, flags) = `callName Params`(c)

    push: 0

    let (memOffset, memLength) = if calcMemSize(memInPos, memInLen) > calcMemSize(memOutPos, memOutLen):
                                    (memInPos, memInLen)
                                 else:
                                    (memOutPos, memOutLen)

    let contractAddress = when opCode in {Call, StaticCall}: destination else: c.msg.contractAddress
    var (childGasFee, childGasLimit) = c.gasCosts[opCode].c_handler(
      value,
      GasParams(kind: opCode,
                c_isNewAccount: not c.accountExists(contractAddress),
                c_gasBalance: c.gasMeter.gasRemaining,
                c_contractGas: gas,
                c_currentMemSize: c.memory.len,
                c_memOffset: memOffset,
                c_memLength: memLength
      ))

    # EIP 2046
    # reduce gas fee for precompiles
    # from 700 to 40
    when opCode == StaticCall:
      if c.fork >= FkBerlin and destination.toInt <= MaxPrecompilesAddr:
        childGasFee = childGasFee - 660.GasInt

    if childGasFee >= 0:
      c.gasMeter.consumeGas(childGasFee, reason = $opCode)

    c.returnData.setLen(0)

    if c.msg.depth >= MaxCallDepth:
      debug "Computation Failure", reason = "Stack too deep", maximumDepth = MaxCallDepth, depth = c.msg.depth
      # return unused gas
      c.gasMeter.returnGas(childGasLimit)
      return

    if childGasFee < 0 and childGasLimit <= 0:
      raise newException(OutOfGas, "Gas not enough to perform calculation (" & callName.astToStr & ")")

    c.memory.extend(memInPos, memInLen)
    c.memory.extend(memOutPos, memOutLen)

    when opCode in {CallCode, Call}:
      let senderBalance = c.getBalance(sender)
      if senderBalance < value:
        debug "Insufficient funds", available = senderBalance, needed = c.msg.value
        # return unused gas
        c.gasMeter.returnGas(childGasLimit)
        return

    when evmc_enabled:
      let msg = nimbus_message(
        kind: callKind.evmc_call_kind,
        depth: (c.msg.depth + 1).int32,
        gas: childGasLimit,
        sender: sender,
        destination: destination,
        input_data: c.memory.readPtr(memInPos),
        input_size: memInLen.uint,
        value: toEvmc(value),
        flags: flags.uint32
      )

      var res = c.host.call(msg)
      c.returnData = @(makeOpenArray(res.outputData, res.outputSize.int))

      let actualOutputSize = min(memOutLen, c.returnData.len)
      if actualOutputSize > 0:
        c.memory.write(memOutPos,
          c.returnData.toOpenArray(0, actualOutputSize - 1))

      c.gasMeter.returnGas(res.gas_left)

      if res.status_code == EVMC_SUCCESS:
        c.stack.top(1)

      # TODO: a good candidate for destructor
      if not res.release.isNil:
        res.release(res)
    else:
      let msg = Message(
        kind: callKind,
        depth: c.msg.depth + 1,
        gas: childGasLimit,
        sender: sender,
        contractAddress: contractAddress,
        codeAddress: destination,
        value: value,
        data: c.memory.read(memInPos, memInLen),
        flags: flags)

      var child = newComputation(c.vmState, msg)
      child.execCall()

      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top(1)

      c.returnData = child.output
      let actualOutputSize = min(memOutLen, child.output.len)
      if actualOutputSize > 0:
        c.memory.write(memOutPos,
          child.output.toOpenArray(0, actualOutputSize - 1))

genCall(call, Call)
genCall(callCode, CallCode)
genCall(delegateCall, DelegateCall)
genCall(staticCall, StaticCall)

op returnOp, inline = false, startPos, size:
  ## 0xf3, Halt execution returning output data.
  let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)

  c.gasMeter.consumeGas(
    c.gasCosts[Return].m_handler(c.memory.len, pos, len),
    reason = "RETURN"
    )

  c.memory.extend(pos, len)
  c.output = c.memory.read(pos, len)

op revert, inline = false, startPos, size:
  ## 0xfd, Halt execution reverting state changes but returning data and remaining gas.
  let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
  c.gasMeter.consumeGas(
    c.gasCosts[Revert].m_handler(c.memory.len, pos, len),
    reason = "REVERT"
    )

  c.memory.extend(pos, len)
  c.output = c.memory.read(pos, len)
  # setError(msg, false) will signal cheap revert
  c.setError("REVERT opcode executed", false)

op selfDestruct, inline = false:
  ## 0xff Halt execution and register account for later deletion.
  let beneficiary = c.stack.popAddress()
  c.selfDestruct(beneficiary)

op selfDestructEip150, inline = false:
  let beneficiary = c.stack.popAddress()

  let gasParams = GasParams(kind: SelfDestruct,
    sd_condition: not c.accountExists(beneficiary)
    )

  let gasCost = c.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
  c.gasMeter.consumeGas(gasCost, reason = "SELFDESTRUCT EIP150")
  c.selfDestruct(beneficiary)

op selfDestructEip161, inline = false:
  checkInStaticContext(c)

  let
    beneficiary = c.stack.popAddress()
    isDead      = not c.accountExists(beneficiary)
    balance     = c.getBalance(c.msg.contractAddress)

  let gasParams = GasParams(kind: SelfDestruct,
    sd_condition: isDead and not balance.isZero
    )

  let gasCost = c.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
  c.gasMeter.consumeGas(gasCost, reason = "SELFDESTRUCT EIP161")
  c.selfDestruct(beneficiary)

# Constantinople's new opcodes
op shlOp, inline = true, shift, num:
  let shiftLen = shift.safeInt
  if shiftLen >= 256:
    push: 0
  else:
    push: num shl shiftLen

op shrOp, inline = true, shift, num:
  let shiftLen = shift.safeInt
  if shiftLen >= 256:
    push: 0
  else:
    # uint version of `shr`
    push: num shr shiftLen

op sarOp, inline = true:
  let shiftLen = c.stack.popInt().safeInt
  let num = cast[Int256](c.stack.popInt())
  if shiftLen >= 256:
    if num.isNegative:
      push: cast[Uint256]((-1).i256)
    else:
      push: 0
  else:
    # int version of `shr` then force the result
    # into uint256
    push: cast[Uint256](num shr shiftLen)

op extCodeHash, inline = true:
  let address = c.stack.popAddress()
  push: c.getCodeHash(address)

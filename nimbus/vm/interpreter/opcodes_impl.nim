# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, times, stew/ranges, sequtils, options,
  chronicles, stint, nimcrypto, stew/ranges/typedranges, eth/common,
  ./utils/[macros_procs_opcodes, utils_numeric],
  ./gas_meter, ./gas_costs, ./opcode_values, ./vm_forks,
  ../memory, ../message, ../stack, ../code_stream, ../computation,
  ../../vm_state, ../../errors, ../../constants, ../../vm_types,
  ../../db/[db_chain, state_db], ../../utils

logScope:
  topics = "opcode impl"

# ##################################
# Syntactic sugar

template push(x: typed) {.dirty.} =
  ## Push an expression on the computation stack
  computation.stack.push x

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
  computation.gasMeter.consumeGas(
    computation.gasCosts[Exp].d_handler(exponent),
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

  computation.gasMeter.consumeGas(
    computation.gasCosts[Op.Sha3].m_handler(computation.memory.len, pos, len),
    reason="SHA3: word gas cost"
    )

  computation.memory.extend(pos, len)
  let endRange = min(pos + len, computation.memory.len) - 1
  if endRange == -1 or pos >= computation.memory.len:
    push(EMPTY_SHA3)
  else:
    push:
      keccak256.digest computation.memory.bytes.toOpenArray(pos, endRange)

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
  push: computation.msg.contractAddress

op balance, inline = true:
  ## 0x31, Get balance of the given account.
  let address = computation.stack.popAddress()
  push: computation.vmState.readOnlyStateDB.getBalance(address)

op origin, inline = true:
  ## 0x32, Get execution origination address.
  push: computation.msg.origin

op caller, inline = true:
  ## 0x33, Get caller address.
  push: computation.msg.sender

op callValue, inline = true:
  ## 0x34, Get deposited value by the instruction/transaction
  ##       responsible for this execution
  push: computation.msg.value

op callDataLoad, inline = false, startPos:
  ## 0x35, Get input data of current environment
  let start = startPos.cleanMemRef
  if start >= computation.msg.data.len:
    push: 0
    return

  # If the data does not take 32 bytes, pad with zeros
  let endRange = min(computation.msg.data.len - 1, start + 31)
  let presentBytes = endRange - start
  # We rely on value being initialized with 0 by default
  var value: array[32, byte]
  value[0 .. presentBytes] = computation.msg.data.toOpenArray(start, endRange)

  push: value

op callDataSize, inline = true:
  ## 0x36, Get size of input data in current environment.
  push: computation.msg.data.len.u256

op callDataCopy, inline = false, memStartPos, copyStartPos, size:
  ## 0x37, Copy input data in current environment to memory.
  # TODO tests: https://github.com/status-im/nimbus/issues/67

  let (memPos, copyPos, len) = (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CallDataCopy].m_handler(computation.memory.len, memPos, len),
    reason="CallDataCopy fee")

  computation.memory.writePaddedResult(computation.msg.data, memPos, copyPos, len)

op codeSize, inline = true:
  ## 0x38, Get size of code running in current environment.
  push: computation.code.len

op codeCopy, inline = false, memStartPos, copyStartPos, size:
  ## 0x39, Copy code running in current environment to memory.
  # TODO tests: https://github.com/status-im/nimbus/issues/67

  let (memPos, copyPos, len) = (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CodeCopy].m_handler(computation.memory.len, memPos, len),
    reason="CodeCopy fee")

  computation.memory.writePaddedResult(computation.code.bytes, memPos, copyPos, len)

op gasprice, inline = true:
  ## 0x3A, Get price of gas in current environment.
  push: computation.msg.gasPrice

op extCodeSize, inline = true:
  ## 0x3b, Get size of an account's code
  let account = computation.stack.popAddress()
  let codeSize = computation.vmState.readOnlyStateDB.getCode(account).len
  push uint(codeSize)

op extCodeCopy, inline = true:
  ## 0x3c, Copy an account's code to memory.
  let account = computation.stack.popAddress()
  let (memStartPos, codeStartPos, size) = computation.stack.popInt(3)
  let (memPos, codePos, len) = (memStartPos.cleanMemRef, codeStartPos.cleanMemRef, size.cleanMemRef)

  computation.gasMeter.consumeGas(
    computation.gasCosts[ExtCodeCopy].m_handler(computation.memory.len, memPos, len),
    reason="ExtCodeCopy fee")

  let codeBytes = computation.vmState.readOnlyStateDB.getCode(account)
  computation.memory.writePaddedResult(codeBytes.toOpenArray, memPos, codePos, len)

op returnDataSize, inline = true:
  ## 0x3d, Get size of output data from the previous call from the current environment.
  push: computation.returnData.len

op returnDataCopy, inline = false,  memStartPos, copyStartPos, size:
  ## 0x3e, Copy output data from the previous call to memory.
  let (memPos, copyPos, len) = (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)
  let gasCost = computation.gasCosts[ReturnDataCopy].m_handler(computation.memory.len, memPos, len)
  computation.gasMeter.consumeGas(
    gasCost,
    reason="returnDataCopy fee")

  if copyPos + len > computation.returnData.len:
    # TODO Geth additionally checks copyPos + len < 64
    #      Parity uses a saturating addition
    #      Yellow paper mentions  μs[1] + i are not subject to the 2^256 modulo.
    raise newException(OutOfBoundsRead,
      "Return data length is not sufficient to satisfy request.  Asked \n" &
      &"for data from index {copyStartPos} to {copyStartPos + size}. Return data is {computation.returnData.len} in \n" &
      "length")

  computation.memory.writePaddedResult(computation.returnData, memPos, copyPos, len)

# ##########################################
# 40s: Block Information

op blockhash, inline = true, blockNumber:
  ## 0x40, Get the hash of one of the 256 most recent complete blocks.
  push: computation.vmState.getAncestorHash(blockNumber.vmWordToBlockNumber)

op coinbase, inline = true:
  ## 0x41, Get the block's beneficiary address.
  push: computation.vmState.coinbase

op timestamp, inline = true:
  ## 0x42, Get the block's timestamp.
  push: computation.vmState.timestamp.toUnix

op blocknumber, inline = true:
  ## 0x43, Get the block's number.
  push: computation.vmState.blockNumber.blockNumberToVmWord

op difficulty, inline = true:
  ## 0x44, Get the block's difficulty
  push: computation.vmState.difficulty

op gasLimit, inline = true:
  ## 0x45, Get the block's gas limit
  push: computation.vmState.gasLimit

op chainId, inline = true:
  ## 0x46, Get current chain’s EIP-155 unique identifier.
  # TODO: this is a stub
  push: computation.vmState.chaindb.config.chainId

op selfBalance, inline = true:
  ## 0x47, Get current contract's balance.
  let stateDb = computation.vmState.readOnlyStateDb
  push: stateDb.getBalance(computation.msg.contractAddress)

# ##########################################
# 50s: Stack, Memory, Storage and Flow Operations

op pop, inline = true:
  ## 0x50, Remove item from stack.
  discard computation.stack.popInt()

op mload, inline = true, memStartPos:
  ## 0x51, Load word from memory
  let memPos = memStartPos.cleanMemRef

  computation.gasMeter.consumeGas(
    computation.gasCosts[MLoad].m_handler(computation.memory.len, memPos, 32),
    reason="MLOAD: GasVeryLow + memory expansion"
    )
  computation.memory.extend(memPos, 32)

  push: computation.memory.read(memPos, 32) # TODO, should we convert to native endianness?

op mstore, inline = true, memStartPos, value:
  ## 0x52, Save word to memory
  let memPos = memStartPos.cleanMemRef

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore].m_handler(computation.memory.len, memPos, 32),
    reason="MSTORE: GasVeryLow + memory expansion"
    )

  computation.memory.extend(memPos, 32)
  computation.memory.write(memPos, value.toByteArrayBE) # is big-endian correct? Parity/Geth do convert

op mstore8, inline = true, memStartPos, value:
  ## 0x53, Save byte to memory
  let memPos = memStartPos.cleanMemRef

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore].m_handler(computation.memory.len, memPos, 1),
    reason="MSTORE8: GasVeryLow + memory expansion"
    )

  computation.memory.extend(memPos, 1)
  computation.memory.write(memPos, [value.toByteArrayBE[31]])

op sload, inline = true, slot:
  ## 0x54, Load word from storage.

  let (value, _) = computation.vmState.readOnlyStateDB.getStorage(computation.msg.contractAddress, slot)
  push(value)

op sstore, inline = false, slot, value:
  ## 0x55, Save word to storage.
  checkInStaticContext(computation)

  let (currentValue, existing) = computation.vmState.readOnlyStateDB.getStorage(computation.msg.contractAddress, slot)

  let
    gasParam = GasParams(kind: Op.Sstore, s_isStorageEmpty: currentValue.isZero)
    (gasCost, gasRefund) = computation.gasCosts[Sstore].c_handler(value, gasParam)

  computation.gasMeter.consumeGas(gasCost, &"SSTORE: {computation.msg.contractAddress}[{slot}] -> {value} ({currentValue})")

  if gasRefund > 0:
    computation.gasMeter.refundGas(gasRefund)

  computation.vmState.mutateStateDB:
    db.setStorage(computation.msg.contractAddress, slot, value)

proc jumpImpl(computation: BaseComputation, jumpTarget: UInt256) =
  if jumpTarget >= computation.code.len.u256:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")

  let jt = jumpTarget.truncate(int)
  computation.code.pc = jt

  let nextOpcode = computation.code.peek
  if nextOpcode != JUMPDEST:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")
  # TODO: next check seems redundant
  if not computation.code.isValidOpcode(jt):
    raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

op jump, inline = true, jumpTarget:
  ## 0x56, Alter the program counter
  jumpImpl(computation, jumpTarget)

op jumpI, inline = true, jumpTarget, testedValue:
  ## 0x57, Conditionally alter the program counter.
  if testedValue != 0:
    jumpImpl(computation, jumpTarget)

op pc, inline = true:
  ## 0x58, Get the value of the program counter prior to the increment corresponding to this instruction.
  push: max(computation.code.pc - 1, 0)

op msize, inline = true:
  ## 0x59, Get the size of active memory in bytes.
  push: computation.memory.len

op gas, inline = true:
  ## 0x5a, Get the amount of available gas, including the corresponding reduction for the cost of this instruction.
  push: computation.gasMeter.gasRemaining

op jumpDest, inline = true:
  ## 0x5b, Mark a valid destination for jumps. This operation has no effect on machine state during execution.
  discard

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

proc canTransfer(computation: BaseComputation, memPos, memLen: int, value: Uint256, opCode: static[Op]): bool =
  let gasParams = GasParams(kind: Create,
    cr_currentMemSize: computation.memory.len,
    cr_memOffset: memPos,
    cr_memLength: memLen
    )
  var gasCost = computation.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
  let reason = &"CREATE: GasCreate + {memLen} * memory expansion"

  when opCode == Create2:
    gasCost = gasCost + computation.gasCosts[Create2].m_handler(0, 0, memLen)

  computation.gasMeter.consumeGas(gasCost, reason = reason)
  computation.memory.extend(memPos, memLen)

  # the sender is childmsg sender, not parent msg sender
  # perhaps we need to move this code somewhere else
  # to avoid confusion
  let senderBalance =
    computation.vmState.readOnlyStateDb().
      getBalance(computation.msg.contractAddress)

  if senderBalance < value:
    debug "Computation Failure", reason = "Insufficient funds available to transfer", required = computation.msg.value, balance = senderBalance
    return false

  # unlike the other MaxCallDepth comparison,
  # this one has not been entered child computation
  # thats why it has `+ 1`
  if computation.msg.depth + 1 > MaxCallDepth:
    debug "Computation Failure", reason = "Stack too deep", maximumDepth = MaxCallDepth, depth = computation.msg.depth
    return false

  result = true

proc setupCreate(computation: BaseComputation, memPos, len: int, value: Uint256, opCode: static[Op]): BaseComputation =
  let
    callData = computation.memory.read(memPos, len)

  var
    createMsgGas = computation.getGasRemaining()

  if computation.fork >= FkTangerine:
    createMsgGas -= createMsgGas div 64

  # Consume gas here that will be passed to child
  computation.gasMeter.consumeGas(createMsgGas, reason="CREATE")

  # Generate new address and check for collisions
  var
    contractAddress: EthAddress
    isCollision: bool

  when opCode == Create:
    const callKind = evmcCreate
    computation.vmState.mutateStateDB:
      # Regarding collisions, see: https://github.com/status-im/nimbus/issues/133
      # See: https://github.com/ethereum/EIPs/issues/684
      let creationNonce = db.getNonce(computation.msg.contractAddress)
      db.setNonce(computation.msg.contractAddress, creationNonce + 1)

      contractAddress = generateAddress(computation.msg.contractAddress, creationNonce)
      isCollision = db.hasCodeOrNonce(contractAddress)
  else:
    const callKind = evmcCreate2
    computation.vmState.mutateStateDB:
      db.incNonce(computation.msg.contractAddress)
      let salt = computation.stack.popInt()
      contractAddress = generateSafeAddress(computation.msg.contractAddress, salt, callData)
      isCollision = db.hasCodeOrNonce(contractAddress)

  if isCollision:
    debug "Address collision while creating contract", address = contractAddress.toHex
    push: 0
    return

  let childMsg = Message(
    kind: callKind,
    depth: computation.msg.depth + 1,
    gas: createMsgGas,
    gasPrice: computation.msg.gasPrice,
    origin: computation.msg.origin,
    sender: computation.msg.contractAddress,
    contractAddress: contractAddress,
    codeAddress: CREATE_CONTRACT_ADDRESS,
    value: value,
    data: @[],
    code: callData
    )

  result = newBaseComputation(
    computation.vmState,
    childMsg,
    some(computation.fork))

template genCreate(callName: untyped, opCode: Op): untyped =
  op callName, inline = false, val, startPosition, size:
    ## 0xf0, Create a new account with associated code.
    let (memPos, len) = (startPosition.safeInt, size.safeInt)
    if not computation.canTransfer(memPos, len, val, opCode):
      push: 0
      return

    var childComp = setupCreate(computation, memPos, len, val, opCode)
    if childComp.isNil: return

    continuation(childComp):
      addChildComputation(computation, childComp)

      if childComp.isError:
        push: 0
      else:
        push: childComp.msg.contractAddress

    checkInStaticContext(computation)
    childComp.applyMessage(Create)

genCreate(create, Create)
genCreate(create2, Create2)

proc callParams(computation: BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, CallKind, UInt256, UInt256, UInt256, UInt256, MsgFlags) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

  let (value,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(5)

  result = (gas,
    value,
    codeAddress, # contractAddress
    computation.msg.contractAddress, # sender
    codeAddress,
    evmcCall,
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    computation.msg.flags)

proc callCodeParams(computation: BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, CallKind, UInt256, UInt256, UInt256, UInt256, MsgFlags) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

  let (value,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(5)

  result = (gas,
    value,
    computation.msg.contractAddress, # contractAddress
    computation.msg.contractAddress, # sender
    codeAddress,
    evmcCallCode,
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    computation.msg.flags)

proc delegateCallParams(computation: BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, CallKind, UInt256, UInt256, UInt256, UInt256, MsgFlags) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

  let (memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(4)

  result = (gas,
    computation.msg.value, # value
    computation.msg.contractAddress, # contractAddress
    computation.msg.sender, # sender
    codeAddress,
    evmcDelegateCall,
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    computation.msg.flags)

proc staticCallParams(computation: BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, CallKind, UInt256, UInt256, UInt256, UInt256, MsgFlags) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

  let (memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(4)

  result = (gas,
    0.u256, # value
    codeAddress, # contractAddress
    computation.msg.contractAddress, # sender
    codeAddress,
    evmcCall,
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    emvcStatic) # is_static

template genCall(callName: untyped, opCode: Op): untyped =
  proc `callName Setup`(computation: BaseComputation, callNameStr: string): BaseComputation =
    let (gas, value, contractAddress, sender,
          codeAddress, callKind,
          memoryInputStartPosition, memoryInputSize,
          memoryOutputStartPosition, memoryOutputSize,
          flags) = `callName Params`(computation)

    let (memInPos, memInLen, memOutPos, memOutLen) = (memoryInputStartPosition.cleanMemRef, memoryInputSize.cleanMemRef, memoryOutputStartPosition.cleanMemRef, memoryOutputSize.cleanMemRef)

    let isNewAccount = if computation.fork >= FkSpurious:
                         computation.vmState.readOnlyStateDb.isDeadAccount(contractAddress)
                       else:
                         not computation.vmState.readOnlyStateDb.accountExists(contractAddress)

    let (memOffset, memLength) = if calcMemSize(memInPos, memInLen) > calcMemSize(memOutPos, memOutLen):
                                    (memInPos, memInLen)
                                 else:
                                    (memOutPos, memOutLen)

    let (childGasFee, childGasLimit) = computation.gasCosts[opCode].c_handler(
      value,
      GasParams(kind: opCode,
                c_isNewAccount: isNewAccount,
                c_gasBalance: computation.gasMeter.gasRemaining,
                c_contractGas: gas,
                c_currentMemSize: computation.memory.len,
                c_memOffset: memOffset,
                c_memLength: memLength
      ))

    if childGasFee >= 0:
      computation.gasMeter.consumeGas(childGasFee, reason = $opCode)

    if childGasFee < 0 and childGasLimit <= 0:
      raise newException(OutOfGas, "Gas not enough to perform calculation (" & callNameStr & ")")

    computation.memory.extend(memInPos, memInLen)
    computation.memory.extend(memOutPos, memOutLen)

    let
      callData = computation.memory.read(memInPos, memInLen)
      code = computation.vmState.readOnlyStateDb.getCode(codeAddress)

    var childMsg = Message(
      kind: callKind,
      depth: computation.msg.depth + 1,
      gas: childGasLimit,
      gasPrice: computation.msg.gasPrice,
      origin: computation.msg.origin,
      sender: sender,
      contractAddress: contractAddress,
      codeAddress: codeAddress,
      value: value,
      data: callData,
      code: code.toSeq,
      flags: flags)

    var childComp = newBaseComputation(
      computation.vmState,
      childMsg,
      some(computation.fork))

    computation.memOutPos = memOutPos
    computation.memOutLen = memOutLen
    result = childComp

  op callName, inline = false:
    ## CALL, 0xf1, Message-Call into an account
    ## CALLCODE, 0xf2, Message-call into this account with an alternative account's code.
    ## DELEGATECALL, 0xf4, Message-call into this account with an alternative account's code, but persisting the current values for sender and value.
    ## STATICCALL, 0xfa, Static message-call into an account.
    var childComp = `callName Setup`(computation, callName.astToStr)

    continuation(childComp):
      addChildComputation(computation, childComp)

      if childComp.isError:
        push: 0
      else:
        push: 1

      if not childComp.shouldEraseReturnData:
        let actualOutputSize = min(computation.memOutLen, childComp.output.len)
        computation.memory.write(
          computation.memOutPos,
          childComp.output.toOpenArray(0, actualOutputSize - 1))

    when opCode == Call:
      if emvcStatic == computation.msg.flags and childComp.msg.value > 0.u256:
        raise newException(StaticContextError, "Cannot modify state while inside of a STATICCALL context")

    childComp.applyMessage(opCode)

genCall(call, Call)
genCall(callCode, CallCode)
genCall(delegateCall, DelegateCall)
genCall(staticCall, StaticCall)

op returnOp, inline = false, startPos, size:
  ## 0xf3, Halt execution returning output data.
  let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Return].m_handler(computation.memory.len, pos, len),
    reason = "RETURN"
    )

  computation.memory.extend(pos, len)
  computation.output = computation.memory.read(pos, len)

op revert, inline = false, startPos, size:
  ## 0xfd, Halt execution reverting state changes but returning data and remaining gas.
  let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
  computation.gasMeter.consumeGas(
    computation.gasCosts[Revert].m_handler(computation.memory.len, pos, len),
    reason = "REVERT"
    )

  computation.memory.extend(pos, len)
  computation.output = computation.memory.read(pos, len)
  # setError(msg, false) will signal cheap revert
  computation.setError("REVERT opcode executed", false)

proc selfDestructImpl(computation: BaseComputation, beneficiary: EthAddress) =
  ## 0xff Halt execution and register account for later deletion.
  # TODO: This is the basic implementation of the self destruct op,
  # Other forks have some extra functionality around this call.
  # In particular, EIP150 and EIP161 have extra requirements.
  computation.vmState.mutateStateDB:
    let
      localBalance = db.getBalance(computation.msg.contractAddress)
      beneficiaryBalance = db.getBalance(beneficiary)

    # Transfer to beneficiary
    db.setBalance(beneficiary, localBalance + beneficiaryBalance)

    # Zero the balance of the address being deleted.
    # This must come after sending to beneficiary in case the
    # contract named itself as the beneficiary.
    db.setBalance(computation.msg.contractAddress, 0.u256)

    # Register the account to be deleted
    computation.registerAccountForDeletion(beneficiary)

    trace "SELFDESTRUCT",
      contractAddress = computation.msg.contractAddress.toHex,
      localBalance = localBalance.toString,
      beneficiary = beneficiary.toHex

op selfDestruct, inline = false:
  let beneficiary = computation.stack.popAddress()
  selfDestructImpl(computation, beneficiary)

op selfDestructEip150, inline = false:
  let beneficiary = computation.stack.popAddress()

  let gasParams = GasParams(kind: SelfDestruct,
    sd_condition: not computation.vmState.readOnlyStateDb.accountExists(beneficiary)
    )

  let gasCost = computation.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
  computation.gasMeter.consumeGas(gasCost, reason = "SELFDESTRUCT EIP150")
  selfDestructImpl(computation, beneficiary)

op selfDestructEip161, inline = false:
  checkInStaticContext(computation)

  let
    beneficiary = computation.stack.popAddress()
    stateDb     = computation.vmState.readOnlyStateDb
    isDead      = stateDb.isDeadAccount(beneficiary)
    balance     = stateDb.getBalance(computation.msg.contractAddress)

  let gasParams = GasParams(kind: SelfDestruct,
    sd_condition: isDead and not balance.isZero
    )

  let gasCost = computation.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
  computation.gasMeter.consumeGas(gasCost, reason = "SELFDESTRUCT EIP161")
  selfDestructImpl(computation, beneficiary)

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
  let shiftLen = computation.stack.popInt().safeInt
  let num = cast[Int256](computation.stack.popInt())
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
  let address = computation.stack.popAddress()
  # this is very inefficient, it calls underlying
  # database too much, we can reduce it by implementing accounts
  # cache
  if not computation.vmState.readOnlyStateDB.accountExists(address):
    push: 0
    return

  if computation.vmState.readOnlyStateDB.isEmptyAccount(address):
    push: 0
  else:
    push: computation.vmState.readOnlyStateDB.getCodeHash(address)

op sstoreEIP2200, inline = false, slot, value:
  checkInStaticContext(computation)
  const SentryGasEIP2200   = 2300  # Minimum gas required to be present for an SSTORE call, not consumed

  if computation.gasMeter.gasRemaining <= SentryGasEIP2200:
    raise newException(OutOfGas, "Gas not enough to perform EIP2200 SSTORE")

  let stateDB = computation.vmState.readOnlyStateDB
  let (currentValue, existing) = stateDB.getStorage(computation.msg.contractAddress, slot)

  let
    gasParam = GasParams(kind: Op.Sstore,
      s_isStorageEmpty: currentValue.isZero,
      s_currentValue: currentValue,
      s_originalValue: stateDB.getCommittedStorage(computation.msg.contractAddress, slot)
    )
    (gasCost, gasRefund) = computation.gasCosts[Sstore].c_handler(value, gasParam)

  computation.gasMeter.consumeGas(gasCost, &"SSTORE EIP2200: {computation.msg.contractAddress}[{slot}] -> {value} ({currentValue})")

  if gasRefund != 0:
    computation.gasMeter.refundGas(gasRefund)

  computation.vmState.mutateStateDB:
    db.setStorage(computation.msg.contractAddress, slot, value)

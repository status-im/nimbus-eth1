# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, times, ranges,
  stint, nimcrypto, ranges/typedranges, eth_common,
  ./utils/[macros_procs_opcodes, utils_numeric],
  ./gas_meter, ./gas_costs, ./opcode_values, ./vm_forks,
  ../memory, ../message, ../stack, ../code_stream, ../computation,
  ../../vm_state, ../../errors, ../../constants, ../../vm_types, ../../logging,
  ../../db/[db_chain, state_db]

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
    const min = (1.u256 shl 255) - 1.u256
    var a = lhs
    var b = rhs
    var signA, signB: bool
    extractSign(a, signA)
    extractSign(b, signB)
    if a == min and b == not zero(UInt256):
      r = min
    else:
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
    if base == 0: zero(UInt256)
    else: base.pow(exponent)

op signExtend, inline = false, bits, value:
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

  let pos = position.toInt

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
  let (pos, len) = (startPos.toInt, length.toInt)

  if pos < 0 or len < 0:
    raise newException(OutOfBoundsRead, "Out of bounds memory access")

  computation.gasMeter.consumeGas(
    computation.gasCosts[Op.Sha3].m_handler(computation.memory.len, pos, len),
    reason="SHA3: word gas cost"
    )

  computation.memory.extend(pos, len)
  let endRange = min(pos + len, computation.memory.len) - 1
  if endRange == -1:
    push(EMPTY_SHA3)
  else:
    push:
      keccak256.digest computation.memory.bytes.toOpenArray(pos, endRange)

# ##########################################
# 30s: Environmental Information

# TODO - simplify: https://github.com/status-im/nimbus/issues/67
proc writePaddedResult(mem: var Memory,
                       data: openarray[byte],
                       memPos, dataPos, len: Natural,
                       paddingValue = 0.byte) =
  mem.extend(memPos, len)

  let dataEndPosition = dataPos + len - 1
  if cast[uint64](dataEndPosition) < cast[uint64](dataPos):
    # unsigned wraparound ("overflow")
    discard
  elif dataEndPosition < data.len:
    mem.write(memPos, data[dataPos .. dataEndPosition])
  else:
    var presentElements = data.len - dataPos
    if presentElements > 0:
      mem.write(memPos, data.toOpenArray(dataPos, data.len - 1))
    else:
      presentElements = 0

  # Note, we don't need to write padding bytes
  # mem.extend already pads with zero properly

op address, inline = true:
  ## 0x30, Get address of currently executing account.
  push: computation.msg.storageAddress

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
  # TODO simplification: https://github.com/status-im/nimbus/issues/67
  let dataPos = startPos.toInt
  if dataPos >= computation.msg.data.len:
    push: 0
    return

  let dataEndPosition = dataPos + 31

  if dataEndPosition < computation.msg.data.len:
    computation.stack.push(computation.msg.data[dataPos .. dataEndPosition])
  else:
    var bytes: array[32, byte]
    var presentBytes = min(computation.msg.data.len - dataPos, 32)

    if presentBytes > 0:
      copyMem(addr bytes[0], addr computation.msg.data[dataPos], presentBytes)
    else:
      presentBytes = 0

    for i in presentBytes ..< 32: bytes[i] = 0
    computation.stack.push(bytes)

op callDataSize, inline = true:
  ## 0x36, Get size of input data in current environment.
  push: computation.msg.data.len.u256

op callDataCopy, inline = false, memStartPos, copyStartPos, size:
  ## 0x37, Copy input data in current environment to memory.
  # TODO tests: https://github.com/status-im/nimbus/issues/67

  let (memPos, copyPos, len) = (memStartPos.toInt, copyStartPos.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CallDataCopy].m_handler(memPos, copyPos, len),
    reason="CallDataCopy fee")

  computation.memory.writePaddedResult(computation.code.bytes, memPos, copyPos, len)

op codesize, inline = true:
  ## 0x38, Get size of code running in current environment.
  push: computation.code.len

op codecopy, inline = false, memStartPos, copyStartPos, size:
  ## 0x39, Copy code running in current environment to memory.
  # TODO tests: https://github.com/status-im/nimbus/issues/67

  let (memPos, copyPos, len) = (memStartPos.toInt, cast[uint64](copyStartPos.toInt), size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CodeCopy].m_handler(memPos, copyPos, len),
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

  # It might be possible to cast this further down the callstack, but
  # that risks creating competing interpretations of same param; this
  # tends to be a ripe design for security vulns, vs a single "gate".
  let (memPos, codePos, len) = (memStartPos.toInt, cast[uint64](codeStartPos), size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[ExtCodeCopy].m_handler(memPos, codePos, len),
    reason="ExtCodeCopy fee")

  let codeBytes = computation.vmState.readOnlyStateDB.getCode(account)
  computation.memory.writePaddedResult(codeBytes.toOpenArray, memPos, codePos, len)

op returnDataSize, inline = true:
  ## 0x3d, Get size of output data from the previous call from the current environment.
  push: computation.returnData.len

op returnDataCopy, inline = false,  memStartPos, copyStartPos, size:
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
    computation.returnData.toOpenArray(copyPos, copyPos+len)

# ##########################################
# 40s: Block Information

op blockhash, inline = true, blockNumber:
  ## 0x40, Get the hash of one of the 256 most recent complete blocks.
  push: computation.vmState.getAncestorHash(blockNumber)

op coinbase, inline = true:
  ## 0x41, Get the block's beneficiary address.
  push: computation.vmState.coinbase

op timestamp, inline = true:
  ## 0x42, Get the block's timestamp.
  push: computation.vmState.timestamp.toUnix

op blocknumber, inline = true:
  ## 0x43, Get the block's number.
  push: computation.vmState.blockNumber

op difficulty, inline = true:
  ## 0x44, Get the block's difficulty
  push: computation.vmState.difficulty

op gasLimit, inline = true:
  ## 0x45, Get the block's gas limit
  push: computation.vmState.gasLimit

# ##########################################
# 50s: Stack, Memory, Storage and Flow Operations

op pop, inline = true:
  ## 0x50, Remove item from stack.
  discard computation.stack.popInt()

op mload, inline = true, memStartPos:
  ## 0x51, Load word from memory
  let memPos = memStartPos.toInt

  computation.gasMeter.consumeGas(
    computation.gasCosts[MLoad].m_handler(computation.memory.len, memPos, 32),
    reason="MLOAD: GasVeryLow + memory expansion"
    )
  computation.memory.extend(memPos, 32)

  push: computation.memory.read(memPos, 32) # TODO, should we convert to native endianness?

op mstore, inline = true, memStartPos, value:
  ## 0x52, Save word to memory
  let memPos = memStartPos.toInt

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore].m_handler(computation.memory.len, memPos, 32),
    reason="MSTORE: GasVeryLow + memory expansion"
    )

  computation.memory.extend(memPos, 32)
  computation.memory.write(memPos, value.toByteArrayBE) # is big-endian correct? Parity/Geth do convert

op mstore8, inline = true, memStartPos, value:
  ## 0x53, Save byte to memory
  let memPos = memStartPos.toInt

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore].m_handler(computation.memory.len, memPos, 1),
    reason="MSTORE8: GasVeryLow + memory expansion"
    )

  computation.memory.extend(memPos, 1)
  computation.memory.write(memPos, [value.toByteArrayBE[31]])

op sload, inline = true, slot:
  ## 0x54, Load word from storage.

  let (value, _) = computation.vmState.readOnlyStateDB.getStorage(computation.msg.storageAddress, slot)
  push(value)

op sstore, inline = false, slot, value:
  ## 0x55, Save word to storage.

  let (currentValue, existing) = computation.vmState.readOnlyStateDB.getStorage(computation.msg.storageAddress, slot)

  let
    gasParam = GasParams(kind: Op.Sstore, s_isStorageEmpty: currentValue.isZero)
    (gasCost, gasRefund) = computation.gasCosts[Sstore].c_handler(value, gasParam)

  computation.gasMeter.consumeGas(gasCost, &"SSTORE: {computation.msg.storageAddress}[{slot}] -> {value} ({currentValue})")

  if gasRefund > 0:
    computation.gasMeter.refundGas(gasRefund)

  computation.vmState.mutateStateDB:
    db.setStorage(computation.msg.storageAddress, slot, value)

proc jumpImpl(computation: var BaseComputation, jumpTarget: UInt256) =
  if jumpTarget >= computation.code.len.u256:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")

  let jt = jumpTarget.toInt
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

op create, inline = false, value, startPosition, size:
  ## 0xf0, Create a new account with associated code.
  # TODO: Forked create for Homestead

  let (memPos, len) = (startPosition.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CodeCopy].m_handler(computation.memory.len, memPos, len),
    reason="Create fee")

  computation.memory.extend(memPos, len)

  ##### getBalance type error: expression 'db' is of type: proc (vmState: untyped, readOnly: untyped, handler: untyped): untyped{.noSideEffect, gcsafe, locks: <unknown>.}
  # computation.vmState.db(readOnly=true):
  #   when ForkName >= FkHomestead: # TODO this is done in Geth but not Parity and Py-EVM
  #     let insufficientFunds = db.getBalance(computation.msg.storageAddress) < value # TODO check gas balance rollover
  #     let stackTooDeep = computation.msg.depth >= MaxCallDepth

  #     # TODO: error message
  #     if insufficientFunds or stackTooDeep:
  #       push: 0
  #       return
  #   else:
  #     let stackTooDeep = computation.msg.depth >= MaxCallDepth
  #     if stackTooDeep:
  #       push: 0
  #       return

  let callData = computation.memory.read(memPos, len)

  ## TODO dynamic gas that depends on remaining gas

  ##### getNonce type error: expression 'db' is of type: proc (vmState: untyped, readOnly: untyped, handler: untyped): untyped{.noSideEffect, gcsafe, locks: <unknown>.}
  # computation.vmState.db(readOnly=true):
  #   let creationNonce = db.getNonce(computation.msg.storageAddress)
  #   db.incrementNonce(computation.msg.storageAddress)
  let contractAddress = ZERO_ADDRESS # generateContractAddress(computation.msg.storageAddress, creationNonce)

  let isCollision = false # TODO: db.accountHasCodeOrNonce ...

  if isCollision:
    computation.vmState.logger.debug("Address collision while creating contract: " & contractAddress.toHex)
    push: 0
    return

  let childMsg = prepareChildMessage(
    computation,
    gas = 0, # TODO refactor gas
    to = CREATE_CONTRACT_ADDRESS,
    value = value,
    data = @[],
    code = callData,
    options = MessageOptions(createAddress: contractAddress)
    )

  # let childComputation = applyChildBaseComputation(computation, childMsg)
  var childComputation: BaseComputation # TODO - stub
  new childComputation
  childComputation.gasMeter.init(0)

  if childComputation.isError:
    push: 0
  else:
    push: contractAddress
  computation.gasMeter.returnGas(childComputation.gasMeter.gasRemaining)

proc callParams(computation: var BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

  let (value,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(5)

  let to = computation.msg.storageAddress
  let sender = computation.msg.storageAddress

  result = (gas,
    value,
    to,
    sender,
    codeAddress,
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    true,  # should_transfer_value,
    computation.msg.isStatic)

proc callCodeParams(computation: var BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let to = computation.stack.popAddress()

  let (value,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(5)

  result = (gas,
    value,
    to,
    ZERO_ADDRESS,  # sender
    ZERO_ADDRESS,  # code_address
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    true,  # should_transfer_value,
    computation.msg.isStatic)

proc delegateCallParams(computation: var BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

  let (memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(4)

  let to = computation.msg.storageAddress
  let sender = computation.msg.storageAddress
  let value = computation.msg.value

  result = (gas,
    value,
    to,
    sender,
    codeAddress,
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    false,  # should_transfer_value,
    computation.msg.isStatic)

proc staticCallParams(computation: var BaseComputation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let to = computation.stack.popAddress()

  let (memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(4)

  result = (gas,
    0.u256, # value
    to,
    ZERO_ADDRESS, # sender
    ZERO_ADDRESS, # codeAddress
    memoryInputStartPosition,
    memoryInputSize,
    memoryOutputStartPosition,
    memoryOutputSize,
    false,  # should_transfer_value,
    true) # is_static

template genCall(callName: untyped): untyped =
  op callName, inline = false:
    ## CALL, 0xf1, Message-Call into an account
    ## CALLCODE, 0xf2, Message-call into this account with an alternative account's code.
    ## DELEGATECALL, 0xf4, Message-call into this account with an alternative account's code, but persisting the current values for sender and value.
    ## STATICCALL, 0xfa, Static message-call into an account.
    # TODO: forked calls for Homestead

    let (gas, value, to, sender,
          codeAddress,
          memoryInputStartPosition, memoryInputSize,
          memoryOutputStartPosition, memoryOutputSize,
          shouldTransferValue,
          isStatic) = `callName Params`(computation)

    let (memInPos, memInLen, memOutPos, memOutLen) = (memoryInputStartPosition.toInt, memoryInputSize.toInt, memoryOutputStartPosition.toInt, memoryOutputSize.toInt)

    let (gasCost, childMsgGas) = computation.gasCosts[Op.Call].c_handler(
      value,
      GasParams(kind: Call,
                c_isNewAccount: true, # TODO stub
                c_gasBalance: 0,
                c_contractGas: 0,
                c_currentMemSize: computation.memory.len,
                c_memOffset: 0, # TODO make sure if we pass the largest mem requested
                c_memLength: 0  # or an addition of mem requested
      ))

    computation.memory.extend(memInPos, memInLen)
    computation.memory.extend(memOutPos, memOutLen)

    let callData = computation.memory.read(memInPos, memInLen)

    ##### getBalance type error: expression 'db' is of type: proc (vmState: untyped, readOnly: untyped, handler: untyped): untyped{.noSideEffect, gcsafe, locks: <unknown>.}
    # computation.vmState.db(readOnly = true):
    #   let senderBalance = db.getBalance(computation.msg.storageAddress) # TODO check gas balance rollover

    let insufficientFunds = false # shouldTransferValue and senderBalance < value
    let stackTooDeep = computation.msg.depth >= MaxCallDepth

    if insufficientFunds or stackTooDeep:
      computation.returnData = @[]
      var errMessage: string
      if insufficientFunds:
        let senderBalance = -1 # TODO workaround
        # Note: for some reason we can't use strformat here, we get undeclared identifiers
        errMessage = &"Insufficient Funds: have: " & $senderBalance & "need: " & $value
      elif stackTooDeep:
        errMessage = "Stack Limit Reached"
      else:
        raise newException(VMError, "Invariant: Unreachable code path")

      # computation.logger.debug(&"failure: {errMessage}") # TODO: Error: expression 'logger' has no type (or is ambiguous)
      computation.gasMeter.returnGas(childMsgGas)
      push: 0
      return

    ##### getCode type error: expression 'db' is of type: proc (vmState: untyped, readOnly: untyped, handler: untyped): untyped{.noSideEffect, gcsafe, locks: <unknown>.}
    # computation.vmState.db(readOnly = true):
    #   let code =  if codeAddress != ZERO_ADDRESS: db.getCode(codeAddress)
    #               else: db.getCode(to)
    let code: seq[byte] = @[]

    var childMsg = prepareChildMessage(
      computation,
      childMsgGas,
      to,
      value,
      callData,
      code,
      MessageOptions(
        shouldTransferValue: shouldTransferValue,
        isStatic: isStatic)
    )

    if sender != ZERO_ADDRESS:
      childMsg.sender = sender

    # let childComputation = applyChildBaseComputation(computation, childMsg)
    var childComputation: BaseComputation # TODO - stub
    new childComputation
    childComputation.gasMeter.init(0)

    if childComputation.isError:
      push: 0
    else:
      push: 1

    if not childComputation.shouldEraseReturnData:
      let actualOutputSize = min(memOutLen, childComputation.output.len)
      computation.memory.write(
        memOutPos,
        childComputation.output.toOpenArray(0, actualOutputSize - 1))
      if not childComputation.shouldBurnGas:
        computation.gasMeter.returnGas(childComputation.gasMeter.gasRemaining)

genCall(call)
genCall(callCode)
genCall(delegateCall)
genCall(staticCall)

op returnOp, inline = false, startPos, size:
  ## 0xf3, Halt execution returning output data.
  let (pos, len) = (startPos.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Return].m_handler(computation.memory.len, pos, len),
    reason = "RETURN"
    )

  computation.memory.extend(pos, len)
  computation.output = computation.memory.read(pos, len)

op revert, inline = false, startPos, size:
  ## 0xfd, Halt execution reverting state changes but returning data and remaining gas.
  let (pos, len) = (startPos.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Revert].m_handler(computation.memory.len, pos, len),
    reason = "REVERT"
    )

  computation.memory.extend(pos, len)
  computation.output = computation.memory.read(pos, len)

op selfDestruct, inline = false:
  ## 0xff Halt execution and register account for later deletion.
  # TODO: This is the basic implementation of the self destruct op,
  # Other forks have some extra functionality around this call.
  # In particular, EIP150 and EIP161 have extra requirements.
  let beneficiary = computation.stack.popAddress()

  computation.vmState.mutateStateDB:
    let
      local_balance = db.get_balance(computation.msg.storage_address)
      beneficiary_balance = db.get_balance(beneficiary)

    # Transfer to beneficiary
    db.setBalance(beneficiary, local_balance + beneficiary_balance)

    # Zero the balance of the address being deleted.
    # This must come after sending to beneficiary in case the
    # contract named itself as the beneficiary.
    db.set_balance(computation.msg.storage_address, 0.u256)

    # Register the account to be deleted
    computation.registerAccountForDeletion(beneficiary)

    computation.vm_state.logger.debug(
      "SELFDESTRUCT: %s (%s) -> %s" &
      computation.msg.storage_address.toHex &
      local_balance.toString &
      beneficiary.toHex)

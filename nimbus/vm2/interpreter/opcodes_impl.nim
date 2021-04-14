# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, times, sets, sequtils, options,
  chronicles, stint, nimcrypto, eth/common,
  ./utils/[macros_procs_opcodes, v2utils_numeric],
  ./gas_meter, ./v2gas_costs, ./v2opcode_values, ./v2forks,
  ../v2memory, ../stack, ../code_stream, ../v2computation, ../v2state, ../v2types,
  ../../errors, ../../constants,
  ../../db/[db_chain, accounts_cache]

# verify that experimental op table compiles
import
  ./op_handlers, ./op_handlers/oph_defs

logScope:
  topics = "opcode impl"

# ##################################
# Syntactic sugar

proc gasEip2929AccountCheck(c: Computation, address: EthAddress, prevCost = 0.GasInt) =
  c.vmState.mutateStateDB:
    let gasCost = if not db.inAccessList(address):
                    db.accessList(address)
                    ColdAccountAccessCost
                  else:
                    WarmStorageReadCost

    c.gasMeter.consumeGas(gasCost - prevCost, reason = "gasEIP2929AccountCheck")

template push(x: typed) {.dirty.} =
  ## Push an expression on the computation stack
  c.stack.push x

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

template sstoreNetGasMeteringImpl(c: Computation, slot, newValue: Uint256) =
  let stateDB = c.vmState.readOnlyStateDB
  let currentValue {.inject.} = c.getStorage(slot)

  let
    gasParam = GasParams(
      kind: Op.Sstore,
      s_currentValue: currentValue,
      s_originalValue: stateDB.getCommittedStorage(c.msg.contractAddress, slot))
    (gasCost, gasRefund) = c.gasCosts[Sstore].c_handler(newValue, gasParam)

  c.gasMeter.consumeGas(gasCost, &"SSTORE EIP2200: {c.msg.contractAddress}[{slot}] -> {newValue} ({currentValue})")

  if gasRefund != 0:
    c.gasMeter.refundGas(gasRefund)

  c.vmState.mutateStateDB:
    db.setStorage(c.msg.contractAddress, slot, newValue)

# ##################################
# re-implemented OP handlers

var gdbBPHook_counter = 0
proc gdbBPHook*() =
  gdbBPHook_counter.inc
  stderr.write &"*** Hello {gdbBPHook_counter}\n"
  stderr.flushFile

template opHandlerX(callName: untyped; opCode: Op; fork = FkBerlin) =
  proc callName*(c: Computation) =
    gdbBPHook()
    var desc: Vm2Ctx
    desc.cpt = c
    vm2OpHandlers[fork][opCode].exec.run(desc)

template opHandler(callName: untyped; opCode: Op; fork = FkBerlin) =
  proc callName*(c: Computation) =
    var desc: Vm2Ctx
    desc.cpt = c
    vm2OpHandlers[fork][opCode].exec.run(desc)

opHandler            add, Op.Add
opHandler            mul, Op.Mul
opHandler            sub, Op.Sub
opHandler         divide, Op.Div
opHandler           sdiv, Op.Sdiv
opHandler         modulo, Op.Mod
opHandler           smod, Op.Smod
opHandler         addmod, Op.AddMod
opHandler         mulmod, Op.MulMod
opHandler            exp, Op.Exp
opHandler     signExtend, Op.SignExtend
opHandler             lt, Op.Lt
opHandler             gt, Op.Gt
opHandler            slt, Op.Slt
opHandler            sgt, Op.Sgt
opHandler             eq, Op.Eq
opHandler         isZero, Op.IsZero
opHandler          andOp, Op.And
opHandler           orOp, Op.Or
opHandler          xorOp, Op.Xor
opHandler          notOp, Op.Not
opHandler         byteOp, Op.Byte
opHandler           sha3, Op.Sha3
opHandler        address, Op.Address
opHandler        balance, Op.Balance
opHandler         origin, Op.Origin
opHandler         caller, Op.Caller
opHandler      callValue, Op.CallValue
opHandler   callDataLoad, Op.CallDataLoad
opHandler   callDataSize, Op.CallDataSize
opHandler   callDataCopy, Op.CallDataCopy
opHandler       codeSize, Op.CodeSize
opHandler       codeCopy, Op.CodeCopy
opHandler       gasprice, Op.GasPrice
opHandler    extCodeSize, Op.ExtCodeSize
opHandler    extCodeCopy, Op.ExtCodeCopy
opHandler returnDataSize, Op.ReturnDataSize
opHandler returnDataCopy, Op.ReturnDataCopy
opHandler      blockhash, Op.Blockhash
opHandler       coinbase, Op.Coinbase
opHandler      timestamp, Op.Timestamp
opHandler    blocknumber, Op.Number
opHandler     difficulty, Op.Difficulty
opHandler       gasLimit, Op.GasLimit
opHandler        chainId, Op.ChainId
opHandler    selfBalance, Op.SelfBalance
opHandler            pop, Op.Pop
opHandler          mload, Op.Mload
opHandler         mstore, Op.Mstore
opHandler        mstore8, Op.Mstore8
opHandler          sload, Op.Sload
opHandler         sstore, Op.Sstore, FkFrontier
opHandler  sstoreEIP1283, Op.Sstore, FkConstantinople
opHandler  sstoreEIP2200, Op.Sstore
opHandler           jump, Op.Jump
opHandler          jumpI, Op.JumpI
opHandler             pc, Op.Pc
opHandler          msize, Op.Msize
opHandler            gas, Op.Gas
opHandler       jumpDest, Op.JumpDest
opHandler       beginSub, Op.BeginSub
opHandler      returnSub, Op.ReturnSub
opHandler        jumpSub, Op.JumpSub

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

    block:
      let childMsg = Message(
        kind: callKind,
        depth: c.msg.depth + 1,
        gas: createMsgGas,
        sender: c.msg.contractAddress,
        value: endowment,
        data: c.memory.read(memPos, memLen)
        )

      var child = newComputation(c.vmState, childMsg, salt)
      c.chainTo(child):
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

    # EIP2929
    # This came before old gas calculator
    # because it will affect `c.gasMeter.gasRemaining`
    # and further `childGasLimit`
    if c.fork >= FkBerlin:
      c.vmState.mutateStateDB:
        if not db.inAccessList(destination):
          db.accessList(destination)
          # The WarmStorageReadCostEIP2929 (100) is already deducted in the form of a constant `gasCall`
          c.gasMeter.consumeGas(ColdAccountAccessCost - WarmStorageReadCost, reason = "EIP2929 gasCall")

    let contractAddress = when opCode in {Call, StaticCall}: destination else: c.msg.contractAddress
    var (gasCost, childGasLimit) = c.gasCosts[opCode].c_handler(
      value,
      GasParams(kind: opCode,
                c_isNewAccount: not c.accountExists(contractAddress),
                c_gasBalance: c.gasMeter.gasRemaining,
                c_contractGas: gas,
                c_currentMemSize: c.memory.len,
                c_memOffset: memOffset,
                c_memLength: memLength
      ))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    #when opCode == StaticCall:
    #  if c.fork >= FkBerlin and destination.toInt <= MaxPrecompilesAddr:
    #    gasCost = gasCost - 660.GasInt

    if gasCost >= 0:
      c.gasMeter.consumeGas(gasCost, reason = $opCode)

    c.returnData.setLen(0)

    if c.msg.depth >= MaxCallDepth:
      debug "Computation Failure", reason = "Stack too deep", maximumDepth = MaxCallDepth, depth = c.msg.depth
      # return unused gas
      c.gasMeter.returnGas(childGasLimit)
      return

    if gasCost < 0 and childGasLimit <= 0:
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

    block:
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
      c.chainTo(child):
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

opHandler      shlOp, Op.Shl
opHandler      shrOp, Op.Shr
opHandler      sarOp, Op.Sar

op extCodeHash, inline = true:
  let address = c.stack.popAddress()
  push: c.getCodeHash(address)

op balanceEIP2929, inline = true:
  ## 0x31, Get balance of the given account.
  let address = c.stack.popAddress()

  c.gasEip2929AccountCheck(address, gasFees[c.fork][GasBalance])
  push: c.getBalance(address)

op extCodeHashEIP2929, inline = true:
  let address = c.stack.popAddress()
  c.gasEip2929AccountCheck(address, gasFees[c.fork][GasExtCodeHash])
  push: c.getCodeHash(address)

op extCodeSizeEIP2929, inline = true:
  ## 0x3b, Get size of an account's code
  let address = c.stack.popAddress()
  c.gasEip2929AccountCheck(address, gasFees[c.fork][GasExtCode])
  push: c.getCodeSize(address)

op extCodeCopyEIP2929, inline = true:
  ## 0x3c, Copy an account's code to memory.
  let address = c.stack.popAddress()
  let (memStartPos, codeStartPos, size) = c.stack.popInt(3)
  let (memPos, codePos, len) = (memStartPos.cleanMemRef, codeStartPos.cleanMemRef, size.cleanMemRef)

  c.gasMeter.consumeGas(
    c.gasCosts[ExtCodeCopy].m_handler(c.memory.len, memPos, len),
    reason="ExtCodeCopy fee")

  c.gasEip2929AccountCheck(address, gasFees[c.fork][GasExtCode])

  let codeBytes = c.getCode(address)
  c.memory.writePaddedResult(codeBytes, memPos, codePos, len)

op selfDestructEIP2929, inline = false:
  checkInStaticContext(c)

  let
    beneficiary = c.stack.popAddress()
    isDead      = not c.accountExists(beneficiary)
    balance     = c.getBalance(c.msg.contractAddress)

  let gasParams = GasParams(kind: SelfDestruct,
    sd_condition: isDead and not balance.isZero
    )

  var gasCost = c.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost

  c.vmState.mutateStateDB:
    if not db.inAccessList(beneficiary):
      db.accessList(beneficiary)
      gasCost = gasCost + ColdAccountAccessCost

  c.gasMeter.consumeGas(gasCost, reason = "SELFDESTRUCT EIP161")
  c.selfDestruct(beneficiary)

op sloadEIP2929, inline = true, slot:
  ## 0x54, Load word from storage.
  c.vmState.mutateStateDB:
    let gasCost = if not db.inAccessList(c.msg.contractAddress, slot):
                    db.accessList(c.msg.contractAddress, slot)
                    ColdSloadCost
                  else:
                    WarmStorageReadCost
    c.gasMeter.consumeGas(gasCost, reason = "sloadEIP2929")

  push: c.getStorage(slot)

op sstoreEIP2929, inline = false, slot, newValue:
  checkInStaticContext(c)
  const SentryGasEIP2200 = 2300  # Minimum gas required to be present for an SSTORE call, not consumed

  if c.gasMeter.gasRemaining <= SentryGasEIP2200:
    raise newException(OutOfGas, "Gas not enough to perform EIP2200 SSTORE")

  c.vmState.mutateStateDB:
    if not db.inAccessList(c.msg.contractAddress, slot):
      db.accessList(c.msg.contractAddress, slot)
      c.gasMeter.consumeGas(ColdSloadCost, reason = "sstoreEIP2929")

  block:
    sstoreNetGasMeteringImpl(c, slot, newValue)

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
opHandler          shlOp, Op.Shl
opHandler          shrOp, Op.Shr
opHandler          sarOp, Op.Sar
opHandler           sha3, Op.Sha3
opHandler        address, Op.Address

opHandler            balance, Op.Balance, FkFrontier
opHandler     balanceEIP2929, Op.Balance

opHandler         origin, Op.Origin
opHandler         caller, Op.Caller
opHandler      callValue, Op.CallValue
opHandler   callDataLoad, Op.CallDataLoad
opHandler   callDataSize, Op.CallDataSize
opHandler   callDataCopy, Op.CallDataCopy
opHandler       codeSize, Op.CodeSize
opHandler       codeCopy, Op.CodeCopy
opHandler       gasprice, Op.GasPrice

opHandler        extCodeSize, Op.ExtCodeSize, FkFrontier
opHandler extCodeSizeEIP2929, Op.ExtCodeSize

opHandler        extCodeCopy, Op.ExtCodeCopy, FkFrontier
opHandler extCodeCopyEIP2929, Op.ExtCodeCopy

opHandler returnDataSize, Op.ReturnDataSize
opHandler returnDataCopy, Op.ReturnDataCopy

opHandler        extCodeHash, Op.ExtCodeHash, FkFrontier
opHandler extCodeHashEIP2929, Op.ExtCodeHash

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

opHandler              sload, Op.Sload, FkFrontier
opHandler       sloadEIP2929, Op.Sload

opHandler             sstore, Op.Sstore, FkFrontier
opHandler      sstoreEIP1283, Op.Sstore, FkConstantinople
opHandler      sstoreEIP2200, Op.Sstore, FkIstanbul
opHandler      sstoreEIP2929, Op.Sstore

opHandler           jump, Op.Jump
opHandler          jumpI, Op.JumpI
opHandler             pc, Op.Pc
opHandler          msize, Op.Msize
opHandler            gas, Op.Gas
opHandler       jumpDest, Op.JumpDest
opHandler       beginSub, Op.BeginSub
opHandler      returnSub, Op.ReturnSub
opHandler        jumpSub, Op.JumpSub
opHandler          push1, Op.Push1
opHandler          push2, Op.Push2
opHandler          push3, Op.Push3
opHandler          push4, Op.Push4
opHandler          push5, Op.Push5
opHandler          push6, Op.Push6
opHandler          push7, Op.Push7
opHandler          push8, Op.Push8
opHandler          push9, Op.Push9
opHandler         push10, Op.Push10
opHandler         push11, Op.Push11
opHandler         push12, Op.Push12
opHandler         push13, Op.Push13
opHandler         push14, Op.Push14
opHandler         push15, Op.Push15
opHandler         push16, Op.Push16
opHandler         push17, Op.Push17
opHandler         push18, Op.Push18
opHandler         push19, Op.Push19
opHandler         push20, Op.Push20
opHandler         push21, Op.Push21
opHandler         push22, Op.Push22
opHandler         push23, Op.Push23
opHandler         push24, Op.Push24
opHandler         push25, Op.Push25
opHandler         push26, Op.Push26
opHandler         push27, Op.Push27
opHandler         push28, Op.Push28
opHandler         push29, Op.Push29
opHandler         push30, Op.Push30
opHandler         push31, Op.Push31
opHandler         push32, Op.Push32
opHandler           dup1, Op.Dup1
opHandler           dup2, Op.Dup2
opHandler           dup3, Op.Dup3
opHandler           dup4, Op.Dup4
opHandler           dup5, Op.Dup5
opHandler           dup6, Op.Dup6
opHandler           dup7, Op.Dup7
opHandler           dup8, Op.Dup8
opHandler           dup9, Op.Dup9
opHandler          dup10, Op.Dup10
opHandler          dup11, Op.Dup11
opHandler          dup12, Op.Dup12
opHandler          dup13, Op.Dup13
opHandler          dup14, Op.Dup14
opHandler          dup15, Op.Dup15
opHandler          dup16, Op.Dup16
opHandler          swap1, Op.Swap1
opHandler          swap2, Op.Swap2
opHandler          swap3, Op.Swap3
opHandler          swap4, Op.Swap4
opHandler          swap5, Op.Swap5
opHandler          swap6, Op.Swap6
opHandler          swap7, Op.Swap7
opHandler          swap8, Op.Swap8
opHandler          swap9, Op.Swap9
opHandler         swap10, Op.Swap10
opHandler         swap11, Op.Swap11
opHandler         swap12, Op.Swap12
opHandler         swap13, Op.Swap13
opHandler         swap14, Op.Swap14
opHandler         swap15, Op.Swap15
opHandler         swap16, Op.Swap16
opHandler           log0, Op.Log0
opHandler           log1, Op.Log1
opHandler           log2, Op.Log2
opHandler           log3, Op.Log3
opHandler           log4, Op.Log4

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

# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Create Operations
## ======================================
##

{.push raises: [CatchableError].} # basically the annotation type of a `Vm2OpFn`

import
  ../../../constants,
  ../../../errors,
  ../../../common/evmforks,
  ../../../utils/utils,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../gas_meter,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  ./oph_helpers,
  chronicles,
  eth/common,
  eth/common/eth_types,
  stint,
  strformat

when not defined(evmc_enabled):
  import
    ../../state,
    ../../../db/accounts_cache

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when evmc_enabled:
  template execSubCreate(c: Computation; msg: ref nimbus_message) =
    c.chainTo(msg):
      c.gasMeter.returnGas(c.res.gas_left)
      if c.res.status_code == EVMC_SUCCESS:
        c.stack.replaceTopElement(pureStackElement(stackValueFrom(c.res.create_address)))
      elif c.res.status_code == EVMC_REVERT:
        # From create, only use `outputData` if child returned with `REVERT`.
        c.returnData = @(makeOpenArray(c.res.outputData, c.res.outputSize.int))
      if not c.res.release.isNil:
        c.res.release(c.res)

else:
  proc execSubCreate(c: Computation; childMsg: Message;
                    salt: ContractSalt = ZERO_CONTRACTSALT) =
    ## Create new VM -- helper for `Create`-like operations

    # need to provide explicit <c> and <child> for capturing in chainTo proc()
    var
      child = newComputation(c.vmState, childMsg, salt)

    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.replaceTopElement(pureStackElement(stackValueFrom(child.msg.contractAddress)))
      elif not child.error.burnsGas: # Means return was `REVERT`.
        # From create, only use `outputData` if child returned with `REVERT`.
        c.returnData = child.output


# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  createOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf0, Create a new account with associated code
    let cpt = k.cpt
    checkInStaticContext(k.cpt)

    cpt.popStackValues do (endowment, memPosUnsafe, memLenUnsafe: UInt256):
      let
        memPos = memPosUnsafe.safeInt
        memLen = memLenUnsafe.safeInt

      cpt.stack.push(0)

      # EIP-3860
      if cpt.fork >= FkShanghai and memLen > EIP3860_MAX_INITCODE_SIZE:
        trace "Initcode size exceeds maximum", initcodeSize = memLen
        raise newException(InitcodeError,
          &"CREATE: have {memLen}, max {EIP3860_MAX_INITCODE_SIZE}")

      let gasParams = GasParams(
        kind:              Create,
        cr_currentMemSize: cpt.memory.len,
        cr_memOffset:      memPos,
        cr_memLength:      memLen)

      var gasCost = cpt.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
      cpt.gasMeter.consumeGas(
        gasCost, reason = &"CREATE: GasCreate + {memLen} * memory expansion")
      cpt.memory.extend(memPos, memLen)
      cpt.returnData.setLen(0)

      if cpt.msg.depth >= MaxCallDepth:
        debug "Computation Failure",
          reason = "Stack too deep",
          maxDepth = MaxCallDepth,
          depth = cpt.msg.depth
        return

      if endowment != 0:
        let senderBalance = cpt.getBalance(cpt.msg.contractAddress)
        if senderBalance < endowment:
          debug "Computation Failure",
            reason = "Insufficient funds available to transfer",
            required = endowment,
            balance = senderBalance
          return

      var createMsgGas = cpt.gasMeter.gasRemaining
      if cpt.fork >= FkTangerine:
        createMsgGas -= createMsgGas div 64
      cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE")

      when evmc_enabled:
        let
          msg = new(nimbus_message)
          c   = cpt
        msg[] = nimbus_message(
          kind: evmcCreate.ord.evmc_call_kind,
          depth: (cpt.msg.depth + 1).int32,
          gas: createMsgGas,
          sender: cpt.msg.contractAddress,
          input_data: cpt.memory.readPtr(memPos),
          input_size: memLen.uint,
          value: toEvmc(endowment),
          create2_salt: toEvmc(ZERO_CONTRACTSALT),
        )
        c.execSubCreate(msg)
      else:
        cpt.readMemory(memPos, memLen) do (memBytes: seq[byte]):
          cpt.execSubCreate(
            childMsg = Message(
              kind:   evmcCreate,
              depth:  cpt.msg.depth + 1,
              gas:    createMsgGas,
              sender: cpt.msg.contractAddress,
              value:  endowment,
              data:   memBytes))

  # ---------------------

  create2Op: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf5, Behaves identically to CREATE, except using keccak256
    let cpt = k.cpt
    checkInStaticContext(cpt)

    cpt.popStackValues do (endowment, memPosUnsafe, memLenUnsafe, saltInt: UInt256):
      let
        memPos = memPosUnsafe.safeInt
        memLen = memLenUnsafe.safeInt
        salt = ContractSalt(bytes: saltInt.toBytesBE)
      
      cpt.stack.push(0)

      # EIP-3860
      if cpt.fork >= FkShanghai and memLen > EIP3860_MAX_INITCODE_SIZE:
        trace "Initcode size exceeds maximum", initcodeSize = memLen
        raise newException(InitcodeError,
          &"CREATE2: have {memLen}, max {EIP3860_MAX_INITCODE_SIZE}")

      let gasParams = GasParams(
        kind:              Create,
        cr_currentMemSize: cpt.memory.len,
        cr_memOffset:      memPos,
        cr_memLength:      memLen)

      var gasCost = cpt.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
      gasCost = gasCost + cpt.gasCosts[Create2].m_handler(0, 0, memLen)

      cpt.gasMeter.consumeGas(
        gasCost, reason = &"CREATE2: GasCreate + {memLen} * memory expansion")
      cpt.memory.extend(memPos, memLen)
      cpt.returnData.setLen(0)

      if cpt.msg.depth >= MaxCallDepth:
        debug "Computation Failure",
          reason = "Stack too deep",
          maxDepth = MaxCallDepth,
          depth = cpt.msg.depth
        return

      if endowment != 0:
        let senderBalance = cpt.getBalance(cpt.msg.contractAddress)
        if senderBalance < endowment:
          debug "Computation Failure",
            reason = "Insufficient funds available to transfer",
            required = endowment,
            balance = senderBalance
          return

      var createMsgGas = cpt.gasMeter.gasRemaining
      if cpt.fork >= FkTangerine:
        createMsgGas -= createMsgGas div 64
      cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE2")

      when evmc_enabled:
        let
          msg = new(nimbus_message)
          c   = cpt
        msg[] = nimbus_message(
          kind: evmcCreate2.ord.evmc_call_kind,
          depth: (cpt.msg.depth + 1).int32,
          gas: createMsgGas,
          sender: cpt.msg.contractAddress,
          input_data: cpt.memory.readPtr(memPos),
          input_size: memLen.uint,
          value: toEvmc(endowment),
          create2_salt: toEvmc(salt),
        )
        c.execSubCreate(msg)
      else:
        cpt.readMemory(memPos, memLen) do (memBytes: seq[byte]):
          cpt.execSubCreate(
            salt = salt,
            childMsg = Message(
              kind:   evmcCreate2,
              depth:  cpt.msg.depth + 1,
              gas:    createMsgGas,
              sender: cpt.msg.contractAddress,
              value:  endowment,
              data:   memBytes))

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecCreate*: seq[Vm2OpExec] = @[

    (opCode: Create,    ## 0xf0, Create a new account with associated code
     forks: Vm2OpAllForks,
     name: "create",
     info: "Create a new account with associated code",
     exec: (prep: vm2OpIgnore,
            run: createOp,
            post: vm2OpIgnore)),

    (opCode: Create2,   ## 0xf5, Create using keccak256
     forks: Vm2OpConstantinopleAndLater,
     name: "create2",
     info: "Behaves identically to CREATE, except using keccak256",
     exec: (prep: vm2OpIgnore,
            run: create2Op,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

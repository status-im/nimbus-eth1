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
        c.stack.top(c.res.create_address)
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
        c.stack.top child.msg.contractAddress
      elif not child.error.burnsGas: # Means return was `REVERT`.
        # From create, only use `outputData` if child returned with `REVERT`.
        c.returnData = child.output


# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  createOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf0, Create a new account with associated code
    checkInStaticContext(k.cpt)

    let
      endowment = k.cpt.stack.popInt()
      memPos    = k.cpt.stack.popInt().safeInt
      memLen    = k.cpt.stack.peekInt().safeInt

    k.cpt.stack.top(0)

    # EIP-3860
    if k.cpt.fork >= FkShanghai and memLen > EIP3860_MAX_INITCODE_SIZE:
      trace "Initcode size exceeds maximum", initcodeSize = memLen
      raise newException(InitcodeError,
        &"CREATE: have {memLen}, max {EIP3860_MAX_INITCODE_SIZE}")

    let gasParams = GasParams(
      kind:              Create,
      cr_currentMemSize: k.cpt.memory.len,
      cr_memOffset:      memPos,
      cr_memLength:      memLen)

    var gasCost = k.cpt.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
    k.cpt.gasMeter.consumeGas(
      gasCost, reason = &"CREATE: GasCreate + {memLen} * memory expansion")
    k.cpt.memory.extend(memPos, memLen)
    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maxDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      return

    if endowment != 0:
      let senderBalance = k.cpt.getBalance(k.cpt.msg.contractAddress)
      if senderBalance < endowment:
        debug "Computation Failure",
          reason = "Insufficient funds available to transfer",
          required = endowment,
          balance = senderBalance
        return

    var createMsgGas = k.cpt.gasMeter.gasRemaining
    if k.cpt.fork >= FkTangerine:
      createMsgGas -= createMsgGas div 64
    k.cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE")

    when evmc_enabled:
      let
        msg = new(nimbus_message)
        c   = k.cpt
      msg[] = nimbus_message(
        kind: evmcCreate.ord.evmc_call_kind,
        depth: (k.cpt.msg.depth + 1).int32,
        gas: createMsgGas,
        sender: k.cpt.msg.contractAddress,
        input_data: k.cpt.memory.readPtr(memPos),
        input_size: memLen.uint,
        value: toEvmc(endowment),
        create2_salt: toEvmc(ZERO_CONTRACTSALT),
      )
      c.execSubCreate(msg)
    else:
      k.cpt.execSubCreate(
        childMsg = Message(
          kind:   evmcCreate,
          depth:  k.cpt.msg.depth + 1,
          gas:    createMsgGas,
          sender: k.cpt.msg.contractAddress,
          value:  endowment,
          data:   k.cpt.memory.read(memPos, memLen)))

  # ---------------------

  create2Op: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf5, Behaves identically to CREATE, except using keccak256
    checkInStaticContext(k.cpt)

    let
      endowment = k.cpt.stack.popInt()
      memPos    = k.cpt.stack.popInt().safeInt
      memLen    = k.cpt.stack.popInt().safeInt
      salt      = ContractSalt(bytes: k.cpt.stack.peekInt().toBytesBE)

    k.cpt.stack.top(0)

    # EIP-3860
    if k.cpt.fork >= FkShanghai and memLen > EIP3860_MAX_INITCODE_SIZE:
      trace "Initcode size exceeds maximum", initcodeSize = memLen
      raise newException(InitcodeError,
        &"CREATE2: have {memLen}, max {EIP3860_MAX_INITCODE_SIZE}")

    let gasParams = GasParams(
      kind:              Create,
      cr_currentMemSize: k.cpt.memory.len,
      cr_memOffset:      memPos,
      cr_memLength:      memLen)

    var gasCost = k.cpt.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
    gasCost = gasCost + k.cpt.gasCosts[Create2].m_handler(0, 0, memLen)

    k.cpt.gasMeter.consumeGas(
      gasCost, reason = &"CREATE2: GasCreate + {memLen} * memory expansion")
    k.cpt.memory.extend(memPos, memLen)
    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maxDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      return

    if endowment != 0:
      let senderBalance = k.cpt.getBalance(k.cpt.msg.contractAddress)
      if senderBalance < endowment:
        debug "Computation Failure",
          reason = "Insufficient funds available to transfer",
          required = endowment,
          balance = senderBalance
        return

    var createMsgGas = k.cpt.gasMeter.gasRemaining
    if k.cpt.fork >= FkTangerine:
      createMsgGas -= createMsgGas div 64
    k.cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE2")

    when evmc_enabled:
      let
        msg = new(nimbus_message)
        c   = k.cpt
      msg[] = nimbus_message(
        kind: evmcCreate2.ord.evmc_call_kind,
        depth: (k.cpt.msg.depth + 1).int32,
        gas: createMsgGas,
        sender: k.cpt.msg.contractAddress,
        input_data: k.cpt.memory.readPtr(memPos),
        input_size: memLen.uint,
        value: toEvmc(endowment),
        create2_salt: toEvmc(salt),
      )
      c.execSubCreate(msg)
    else:
      k.cpt.execSubCreate(
        salt = salt,
        childMsg = Message(
          kind:   evmcCreate2,
          depth:  k.cpt.msg.depth + 1,
          gas:    createMsgGas,
          sender: k.cpt.msg.contractAddress,
          value:  endowment,
          data:   k.cpt.memory.read(memPos, memLen)))

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

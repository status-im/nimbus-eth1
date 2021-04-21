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

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ../../stack,
  ../../v2memory,
  ../forks_list,
  ../op_codes,
  ../utils/v2utils_numeric,
  chronicles,
  eth/common/eth_types,
  stint,
  strformat

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../constants,
    ../../compu_helper,
    ../../v2computation,
    ../../v2state,
    ../../v2types,
    ../gas_costs,
    ../gas_meter,
    ./oph_defs,
    ./oph_helpers,
    eth/common

else:
  import
    ./oph_defs_kludge,
    ./oph_helpers_kludge

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

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
      salt = 0.u256

    k.cpt.stack.top(0)

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

    let childMsg = Message(
      kind:   evmcCreate,
      depth:  k.cpt.msg.depth + 1,
      gas:    createMsgGas,
      sender: k.cpt.msg.contractAddress,
      value:  endowment,
      data:   k.cpt.memory.read(memPos, memLen))

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, childMsg, salt)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top child.msg.contractAddress
      else:
        c.returnData = child.output

  # ---------------------

  create2Op: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf5, Behaves identically to CREATE, except using keccak256
    checkInStaticContext(k.cpt)

    let
      endowment = k.cpt.stack.popInt()
      memPos    = k.cpt.stack.popInt().safeInt
      memLen    = k.cpt.stack.popInt().safeInt
      salt      = k.cpt.stack.peekInt()

    k.cpt.stack.top(0)

    let gasParams = GasParams(
      kind:              Create,
      cr_currentMemSize: k.cpt.memory.len,
      cr_memOffset:      memPos,
      cr_memLength:      memLen)

    var gasCost = k.cpt.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
    gasCost = gasCost + k.cpt.gasCosts[Create2].m_handler(0, 0, memLen)

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

    let childMsg = Message(
      kind:   evmcCreate2,
      depth:  k.cpt.msg.depth + 1,
      gas:    createMsgGas,
      sender: k.cpt.msg.contractAddress,
      value:  endowment,
      data:   k.cpt.memory.read(memPos, memLen))

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, childMsg, salt)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top child.msg.contractAddress
      else:
        c.returnData = child.output

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

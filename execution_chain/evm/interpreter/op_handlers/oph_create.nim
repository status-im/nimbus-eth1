# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
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

{.push raises: [].} # basically the annotation type of a `VmOpFn`

import
  ../../../constants,
  ../../evm_errors,
  ../../../common/evmforks,
  ../../../utils/utils,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../gas_meter,
  ../op_codes,
  ./oph_defs,
  ./oph_helpers,
  chronicles,
  ../../state,
  ../../message,
  ../../../db/ledger

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc execSubCreate(c: Computation; childMsg: Message;
                   code: CodeBytesRef) =
  ## Create new VM -- helper for `Create`-like operations

  # need to provide explicit <c> and <child> for capturing in chainTo proc()
  var
    child = newComputation(c.vmState, keepStack = false, childMsg, code)

  c.chainTo(child):
    if not child.shouldBurnGas:
      c.gasMeter.returnGas(child.gasMeter.gasRemaining)

    if child.isSuccess:
      c.merge(child)
      c.stack.lsTop child.msg.contractAddress
    elif not child.error.burnsGas: # Means return was `REVERT`.
      # From create, only use `outputData` if child returned with `REVERT`.
      c.returnData = move(child.output)
    ok()


# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------


proc createOp(cpt: VmCpt): EvmResultVoid =
  ## 0xf0, Create a new account with associated code
  ? cpt.checkInStaticContext()
  ? cpt.stack.lsCheck(3)

  let
    endowment = cpt.stack.lsPeekInt(^1)
    memPos    = cpt.stack.lsPeekSafeInt(^2)
    memLen    = cpt.stack.lsPeekSafeInt(^3)

  cpt.stack.lsShrink(2)
  cpt.stack.lsTop(0)

  # EIP-7954
  if cpt.fork >= FkAmsterdam and memLen > EIP7954_MAX_INITCODE_SIZE:
    trace "Initcode size exceeds EIP-7954 maximum", initcodeSize = memLen
    return err(opErr(InvalidInitCode))

  # EIP-3860
  if cpt.fork >= FkShanghai and memLen > EIP3860_MAX_INITCODE_SIZE:
    trace "Initcode size exceeds EIP-3860 maximum", initcodeSize = memLen
    return err(opErr(InvalidInitCode))

  let
    gasParams = GasParamsCr(
      currentMemSize: cpt.memory.len,
      memOffset:      memPos,
      memLength:      memLen)
    gasCost = cpt.gasCosts[Create].cr_handler(1.u256, gasParams)

  ? cpt.opcodeGasCost(Create,
    gasCost, reason = "CREATE: GasCreate + memLen * memory expansion")
  cpt.memory.extend(memPos, memLen)
  cpt.returnData.setLen(0)

  if cpt.msg.depth >= MaxCallDepth:
    debug "Computation Failure",
      reason = "Stack too deep",
      maxDepth = MaxCallDepth,
      depth = cpt.msg.depth
    return ok()

  if endowment != 0:
    let senderBalance = cpt.getBalance(cpt.msg.contractAddress)
    if senderBalance < endowment:
      debug "Computation Failure",
        reason = "Insufficient funds available to transfer",
        required = endowment,
        balance = senderBalance
      return ok()

  var createMsgGas = cpt.gasMeter.gasRemaining
  if cpt.fork >= FkTangerine:
    createMsgGas -= createMsgGas div 64
  ? cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE msg gas")

  var
    childMsg = Message(
      kind:   CallKind.Create,
      depth:  cpt.msg.depth + 1,
      gas:    createMsgGas,
      sender: cpt.msg.contractAddress,
      contractAddress: generateContractAddress(
        cpt.vmState,
        CallKind.Create,
        cpt.msg.contractAddress),
      value:  endowment)
    code = CodeBytesRef.init(cpt.memory.read(memPos, memLen))
  cpt.execSubCreate(childMsg, code)
  ok()

# ---------------------

proc create2Op(cpt: VmCpt): EvmResultVoid =
  ## 0xf5, Behaves identically to CREATE, except using keccak256
  ? cpt.checkInStaticContext()
  ? cpt.stack.lsCheck(4)

  let
    endowment = cpt.stack.lsPeekInt(^1)
    memPos    = cpt.stack.lsPeekSafeInt(^2)
    memLen    = cpt.stack.lsPeekSafeInt(^3)
    salt256   = cpt.stack.lsPeekInt(^4)
    salt      = Bytes32(salt256.toBytesBE)

  cpt.stack.lsShrink(3)
  cpt.stack.lsTop(0)

  # EIP-7954
  if cpt.fork >= FkAmsterdam and memLen > EIP7954_MAX_INITCODE_SIZE:
    trace "Initcode size exceeds EIP-7954 maximum", initcodeSize = memLen
    return err(opErr(InvalidInitCode))

  # EIP-3860
  if cpt.fork >= FkShanghai and memLen > EIP3860_MAX_INITCODE_SIZE:
    trace "Initcode size exceeds EIP-3860 maximum", initcodeSize = memLen
    return err(opErr(InvalidInitCode))

  let
    gasParams = GasParamsCr(
      currentMemSize: cpt.memory.len,
      memOffset:      memPos,
      memLength:      memLen)

  var gasCost = cpt.gasCosts[Create].cr_handler(1.u256, gasParams)
  gasCost = gasCost + cpt.gasCosts[Create2].m_handler(0, 0, memLen)

  ? cpt.opcodeGasCost(Create2,
    gasCost, reason = "CREATE2: GasCreate + memLen * memory expansion")
  cpt.memory.extend(memPos, memLen)
  cpt.returnData.setLen(0)

  if cpt.msg.depth >= MaxCallDepth:
    debug "Computation Failure",
      reason = "Stack too deep",
      maxDepth = MaxCallDepth,
      depth = cpt.msg.depth
    return ok()

  if endowment != 0:
    let senderBalance = cpt.getBalance(cpt.msg.contractAddress)
    if senderBalance < endowment:
      debug "Computation Failure",
        reason = "Insufficient funds available to transfer",
        required = endowment,
        balance = senderBalance
      return ok()

  var createMsgGas = cpt.gasMeter.gasRemaining
  if cpt.fork >= FkTangerine:
    createMsgGas -= createMsgGas div 64
  ? cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE2 msg gas")

  var
    code = CodeBytesRef.init(cpt.memory.read(memPos, memLen))
    childMsg = Message(
      kind:   CallKind.Create2,
      depth:  cpt.msg.depth + 1,
      gas:    createMsgGas,
      sender: cpt.msg.contractAddress,
      contractAddress: generateContractAddress(
        cpt.vmState,
        CallKind.Create2,
        cpt.msg.contractAddress,
        salt,
        code),
      value:  endowment)
  cpt.execSubCreate(childMsg, code)
  ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecCreate*: seq[VmOpExec] = @[

    (opCode: Create,    ## 0xf0, Create a new account with associated code
     forks: VmOpAllForks,
     name: "create",
     info: "Create a new account with associated code",
     exec: createOp),


    (opCode: Create2,   ## 0xf5, Create using keccak256
     forks: VmOpConstantinopleAndLater,
     name: "create2",
     info: "Behaves identically to CREATE, except using keccak256",
     exec: create2Op)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

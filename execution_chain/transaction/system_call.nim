# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  ../evm/[types, state, computation, interpreter_dispatch, code_stream],
  ../db/ledger,
  ../core/[eip8037, eip7702]

from ./call_types import OutputResult

export
  OutputResult

type
  SysCallParams* = object
    vmState*:  BaseVMState          # Chain, database, state, block, fork.
    gasLimit*: GasInt               # Maximum gas available for this call.
    sender*:   addresses.Address    # Sender account.
    to*:       addresses.Address    # Recipient.
    input*:    seq[byte]            # Input data.

proc setupComputation(params: SysCallParams, code: CodeBytesRef): Computation =
  let
    vmState = params.vmState
    stateGasReservoir = if vmState.fork >= FkAmsterdam: SYSTEM_STATE_GAS_RESERVOIR.GasInt
                        else: 0.GasInt
    (codeAddress, code) = if vmState.fork < FkPrague or not code.isDelegation:
                            (params.to, code)
                          else:
                            let
                              delegatedTo = code.toDelegationAddress
                              delegatedCode = vmState.ledger.getCode(delegatedTo)
                            (delegatedTo, delegatedCode)
    msg = Message(
      kind:              CallKind.Call,
      gas:               params.gasLimit,
      stateGasReservoir: stateGasReservoir,
      currentTarget:     params.to,
      codeAddress:       codeAddress,
      sender:            params.sender,
    )
    computation = newComputation(vmState, false, msg, code)

  msg.borrowData(params.input)

  vmState.txCtx = TxContext(
    origin: params.sender,
  )

  # reset global refundCounter counter each time
  # EVM called for a new transaction
  vmState.refundCounter = 0
  vmState.captureStart(computation, params.sender, params.to,
                       false, params.input,
                       params.gasLimit, 0.u256)
  computation

func sysCallGasUsed(c: Computation): GasInt =
  c.msg.gas - c.gasMeter.executionGasLeft - c.gasMeter.stateGasLeft

proc finishRunningComputation(c: Computation, T: type): T =
  let
    gasUsed = sysCallGasUsed(c)

  # evm gas used without intrinsic gas
  c.vmState.captureEnd(c, c.output, gasUsed, c.errorOpt)

  when T is OutputResult:
    if c.isError:
      result.error = c.error.info
    result.output = move(c.output)
  elif T is void:
    discard
  else:
    {.error: "Unknown systemCall output".}

proc preExecComputation(vmState: BaseVMState, currentTarget: Address): Result[CodeBytesRef, string] =
  let code = vmState.ledger.getCode(currentTarget)
  if vmState.fork >= FkPrague:
    if currentTarget == WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS or
       currentTarget == CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS:

      # EIP-7002 and EIP-7215 dictates that the code must be present, or else block is invalid
      if code.len <= 0:
        return err("No code found for withdrawal or consolidation requests contract")

    if vmState.fork >= FkAmsterdam and (
      currentTarget == BUILDER_DEPOSIT_CONTRACT_ADDRESS or
      currentTarget == BUILDER_EXIT_CONTRACT_ADDRESS
    ):
      # EIP-8282 dictates that the code must be present, or else block is invalid
      if code.len <= 0:
        return err("No code found for builder deposit or exit requests contract")
  ok(code)

proc systemCall*(params: SysCallParams, T: type): T =
  let
    vmState = params.vmState
    # Pre-execution sanity checks
    code = vmState.preExecComputation(params.to).valueOr:
      when T is OutputResult:
        return T(error: error)
      elif T is void:
        discard error
        return
      else:
        {.error: "Unknown systemCall output".}
    c = setupComputation(params, code)

  if c.isSuccess:
    c.execCallOrCreate()
    vmState.ledger.persist(c.fork.clearEmptyAccounts())
  else:
    # execCallOrCreate normally disposes the computation, dispose here too
    # otherwise the EVM stack leaks.
    c.dispose()
  finishRunningComputation(c, T)

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
  ../core/eip8037,
  ./call_types

export
  call_types

proc setupComputation(params: CallParams): Computation =
  let
    vmState = params.vmState
    stateGasReservoir = if vmState.fork >= FkAmsterdam: SYSTEM_STATE_GAS_RESERVOIR.GasInt
                        else: 0.GasInt
    msg = Message(
      kind:              CallKind.Call,
      gas:               params.gasLimit,
      stateGasReservoir: stateGasReservoir,
      contractAddress:   params.to,
      codeAddress:       params.to,
      sender:            params.sender,
      value:             params.value,
      data:              params.input,
    )
    code = vmState.ledger.getCode(msg.codeAddress)
    computation = newComputation(vmState, false, msg, code)

  vmState.txCtx = TxContext(
    origin: params.sender,
  )

  # reset global gasRefunded counter each time
  # EVM called for a new transaction
  vmState.gasRefunded = 0
  vmState.captureStart(computation, params.sender, params.to,
                       params.isCreate, params.input,
                       params.gasLimit, params.value)
  computation

func sysCallGasUsed(c: Computation): GasInt =
  c.msg.gas - c.gasMeter.gasRemaining - c.gasMeter.stateGasLeft

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

proc preExecComputation(c: Computation) =
  if c.fork >= FkPrague:
    if c.msg.contractAddress == WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS or
       c.msg.contractAddress == CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS:

      # EIP-7002 and EIP-7215 dicates that the code must be present, or else block is invalid
      if c.code.len <= 0:
        c.setError("No code found for withdrawal or consolidation requests contract")
        return

    if c.fork >= FkAmsterdam and (
      c.msg.contractAddress == BUILDER_DEPOSIT_CONTRACT_ADDRESS or
      c.msg.contractAddress == BUILDER_EXIT_CONTRACT_ADDRESS
    ):
      # EIP-8282 dicates that the code must be present, or else block is invalid
      if c.code.len <= 0:
        c.setError("No code found for builder deposit or exit requests contract")
        return

proc systemCall*(params: CallParams, T: type): T =
  let
    ledger = params.vmState.ledger
    c = setupComputation(params)

  # Pre-execution sanity checks
  c.preExecComputation()
  if c.isSuccess:
    c.execCallOrCreate()
    ledger.persist(clearEmptyAccount = true)
  else:
    # execCallOrCreate normally disposes the computation, dispose here too
    # otherwise the EVM stack leaks.
    c.dispose()
  finishRunningComputation(c, T)

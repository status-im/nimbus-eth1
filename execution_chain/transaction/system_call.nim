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
  ../evm/[types, state, computation, message, interpreter_dispatch],
  ../core/eip8037,
  ./call_types

export
  call_types

proc setupComputation(call: CallParams): Computation =
  let
    vmState = call.vmState
    stateGas = if vmState.fork >= FkAmsterdam: SYSTEM_STATE_GAS_RESERVOIR.GasInt
               else: 0.GasInt
    msg = Message(
      kind:            CallKind.Call,
      gas:             call.gasLimit,
      stateGas:        stateGas,
      contractAddress: call.to,
      codeAddress:     call.to,
      sender:          call.sender,
      value:           call.value,
      data:            call.input,
    )
    code = getCallCode(vmState, msg.codeAddress)
    computation = newComputation(vmState, false, msg, code)

  vmState.txCtx = TxContext(
    origin: call.sender,
  )

  # reset global gasRefunded counter each time
  # EVM called for a new transaction
  vmState.gasRefunded = 0
  vmState.captureStart(computation, call.sender, call.to,
                       call.isCreate, call.input,
                       call.gasLimit, call.value)
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

proc systemCall*(call: CallParams, T: type): T =
  let
    ledger = call.vmState.ledger
    c = setupComputation(call)

  # Pre-execution sanity checks
  c.preExecComputation()
  if c.isSuccess:
    c.execCallOrCreate()
    ledger.persist(clearEmptyAccount = true)
  finishRunningComputation(c, T)

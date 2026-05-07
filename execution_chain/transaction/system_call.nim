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
  ../evm/[types, state, computation, code_stream, interpreter_dispatch],
  ./call_common,
  ./call_types

export
  call_types

proc sysCallGasUsed(c: Computation): GasInt =
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
  let c = setupComputation(call, 0, false)

  # Pre-execution sanity checks
  c.preExecComputation()
  if c.isSuccess:
    c.execCallOrCreate()
  finishRunningComputation(c, T)

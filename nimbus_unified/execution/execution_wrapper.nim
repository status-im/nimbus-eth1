# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles,
  std/[atomics],
  ../configs/nimbus_configs,
  ../../nimbus/nimbus_desc,
  ../../nimbus/nimbus_execution_client

export nimbus_configs

## log
logScope:
  topics = "Execution layer"

proc checkForExecutionShutdown(nimbus: NimbusNode) {.async.} =
  while isShutDownRequired.load() == false:
    await sleepAsync(cNimbusServiceTimeoutMs)

  if isShutDownRequired.load() == true:
    nimbus.state = NimbusState.Stopping

proc executionWrapper*(params: ServiceParameters) {.raises: [CatchableError].} =
  info "execution wrapper:", worker = params.name

  var config = params.layerConfig

  doAssert config.kind == Execution

  try:
    {.gcsafe.}:
      var nimbus = NimbusNode(state: NimbusState.Starting, ctx: newEthContext())
      discard nimbus.checkForExecutionShutdown()
      nimbus.run(config.executionConfig)
  except CatchableError as e:
    fatal "error", message = e.msg
    isShutDownRequired.store(true)

  isShutDownRequired.store(true)
  warn "\tExiting execution layer"

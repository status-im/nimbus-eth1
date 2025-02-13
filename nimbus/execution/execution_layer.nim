# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[atomics, os], chronicles, ../configs/nimbus_configs

export nimbus_configs

logScope:
  topics = "Execution layer"

proc executionLayer*(params: ServiceParameters) {.raises: [CatchableError].} =
  var config = params.layerConfig

  doAssert config.kind == Execution

  try:
    while isShutDownRequired.load() == false:
      info "execution ..."
      sleep(cNimbusServiceTimeoutMs)

    isShutDownRequired.store(true)
  except CatchableError as e:
    fatal "error", message = e.msg
    isShutDownRequired.store(true)

  isShutDownRequired.store(true)
  warn "\tExiting execution layer"

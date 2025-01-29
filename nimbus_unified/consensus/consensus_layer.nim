# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[atomics, os], chronicles, ../configs/nimbus_configs

export nimbus_configs

logScope:
  topics = "Consensus layer"

proc consensusLayer*(params: ServiceParameters) {.raises: [CatchableError].} =
  var config = params.layerConfig

  doAssert config.kind == Consensus

  try:
    while isShutDownRequired.load() == false:
      info "consensus ..."
      sleep(cNimbusServiceTimeoutMs + 1000)

    isShutDownRequired.store(true)
  except CatchableError as e:
    fatal "error", message = e.msg
    isShutDownRequired.store(true)

  isShutDownRequired.store(true)
  warn "\tExiting consensus layer"

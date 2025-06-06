# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[atomics, os],
  chronicles,
  results,
  ../conf,
  ../common/utils,
  ./wrapper_execution,
  ../../execution_chain/config,
  ../../execution_chain/nimbus_desc

logScope:
  topics = "Execution layer"

## Execution Layer handler
proc executionLayerHandler*(channel: ptr Channel[pointer]) =
  var p: pointer
  try:
    p = channel[].recv()
  except Exception as e:
    fatal "service unable to receive configuration", err = e.msg
    quit(QuitFailure)

  let parametersList = deserializeConfigArgs(p).valueOr:
    fatal "unable to parse service data", message = error
    quit(QuitFailure)

  #signal main thread that data is read
  isConfigRead.store(true)

  try:
    {.gcsafe.}:
      var nimbusHandler = NimbusNode(state: NimbusState.Starting, ctx: newEthContext())
      let conf = makeConfig(parametersList)
      nimbusHandler.run(conf)
  except [CatchableError, OSError, IOError, CancelledError, MetricsError]:
    fatal "error", message = getCurrentExceptionMsg()

  warn "\tExiting execution layer"

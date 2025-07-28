# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/[atomics], chronos, chronicles, results, ../conf, ../common/utils

from metrics/chronos_httpserver import MetricsError
from ../../execution_chain/nimbus_execution_client import run
from ../../execution_chain/nimbus_desc import NimbusNode, NimbusState
from ../../execution_chain/config import makeConfig
from ../../execution_chain/common import newEthContext

# Workaround for https://github.com/nim-lang/Nim/issues/24844
from web3 import Quantity
discard newFuture[Quantity]()

logScope:
  topics = "Execution layer"

## Request to shutdown execution layer
var nimbusHandler: NimbusNode
proc shutdownExecution*() =
  nimbusHandler.state = NimbusState.Stopping

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
      nimbusHandler = NimbusNode(state: NimbusState.Starting, ctx: newEthContext())
      let conf = makeConfig(parametersList)
      nimbusHandler.run(conf)
  except [CatchableError, OSError, IOError, CancelledError, MetricsError]:
    fatal "error", message = getCurrentExceptionMsg()

  warn "\tExiting execution layer"

# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import os

when isMainModule:
  echo "Starting Nimbus"
  ## TODO
  ## - make banner and config
  ## - file limits
  ## - check if we have permissions to create data folder if needed
  ## - setup logging

  ## this code snippet requires a conf.nim file (eg: beacon_lc_bridge_conf.nim)
  #   var config = makeBannerAndConfig("Nimbus client ", NimbusConfig)
  #   setupLogging(config.logLevel, config.logStdout, config.logFile)

  ## Graceful shutdown by handling of Ctrl+C signal
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except NimbusTasksError as exc:
        raiseAssert exc.msg # shouldn't happen

    echo "\nCtrl+C pressed. Shutting down working tasks"

    echo "Shutting down now"
    quit(0)

  setControlCHook(controlCHandler)

  while true:
    echo "looping"
    sleep(2000)
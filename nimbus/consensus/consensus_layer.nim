# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms .

{.push raises: [].}

import
  std/[atomics, os],
  chronos,
  chronicles,
  results,
  ../conf,
  ../common/utils,
  ./wrapper_consensus,
  beacon_chain/validators/keystore_management,
  beacon_chain/[beacon_node_status, nimbus_binary_common]

logScope:
  topics = "Consensus layer"

proc startBeaconNode(configs: seq[string]) {.raises: [CatchableError].} =
  proc commandLineParams(): seq[string] =
    configs

  var config = makeBannerAndConfig(
    "clientId", "copyrights", "nimBanner", "SPEC_VERSION", [], BeaconNodeConf
  ).valueOr:
    error "Error starting consensus", err = error
    quit QuitFailure

  # required for db
  if not (checkAndCreateDataDir(string(config.dataDir))):
    quit QuitFailure

  setupLogging(config.logLevel, config.logStdout, config.logFile)

  handleStartUpCmd(config)

## Consensus Layer handler
proc consensusLayerHandler*(channel: ptr Channel[pointer]) =
  var p: pointer
  try:
    p = channel[].recv()
  except Exception as e:
    fatal " service unable to receive configuration", err = e.msg
    quit(QuitFailure)

  let configList = deserializeConfigArgs(p).valueOr:
    fatal "unable to parse service data", message = error
    quit(QuitFailure)

  #signal main thread that data is read
  isConfigRead.store(true)

  try:
    {.gcsafe.}:
      startBeaconNode(configList)
  except CatchableError as e:
    fatal "error", message = e.msg

  warn "\tExiting consensus layer"

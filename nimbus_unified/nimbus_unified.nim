# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[atomics, os, exitprocs],
  chronicles,
  stew/io2,
  consensus/consensus_wrapper,
  execution/execution_wrapper,
  version,
  #eth2
  beacon_chain/[nimbus_binary_common, conf, conf_common],
  beacon_chain/validators/keystore_management

#eth1
from ../nimbus/config import makeConfig

# ------------------------------------------------------------------------------
# Private and helper functions
# ------------------------------------------------------------------------------

## Execution Layer handler
proc executionLayerHandler*(parameters: ServiceParameters) {.thread.} =
  info "Started service:", service = parameters.name
  {.gcsafe.}:
    executionWrapper(parameters)
  info "\tExiting service", service = parameters.name

## Consensus Layer handler
proc consensusLayerHandler*(parameters: ServiceParameters) {.thread.} =
  info "Started service:", service = parameters.name

  ## TODO
  # implement mechanism to check nimbus.state changes
  info "Waiting for execution layer bring up ..."
  sleep(15000)
  {.gcsafe.}:
    consensusWrapper(parameters)
  info "\tExiting service", service = parameters.name

## Waits for services to finish (joinThreads)
proc joinServices*(services: NimbusServicesList) =
  warn "Waiting all services to finish ... "

  for i in 0 .. cNimbusMaxServices - 1:
    if services.serviceList[i].isSome:
      let thread = services.serviceList[i].get()
      if thread.threadHandler.running():
        joinThread(thread.threadHandler)
        services.serviceList[i] = none(NimbusService)
        info "Exited service ", service = thread.name

  notice "Exited all services"

# lock file
var gPidFile: string
proc createPidFile(filename: string) {.raises: [IOError].} =
  writeFile filename, $os.getCurrentProcessId()
  gPidFile = filename
  addExitProc (
    proc() =
      discard io2.removeFile(filename)
  )

## adds a new service to nimbus services list.
proc addNewService(
    services: var NimbusServicesList,
    serviceHandler: proc(config: ServiceParameters) {.thread.},
    parameters: var ServiceParameters,
    timeout: uint32,
) =
  #search next available free worker
  var currentIndex = -1
  for i in 0 .. cNimbusMaxServices - 1:
    if services.serviceList[i].isNone:
      services.serviceList[i] =
        some(NimbusService(name: parameters.name, timeoutMs: timeout))
      currentIndex = i
      parameters.name = parameters.name
      break

  if currentIndex < 0:
    raise newException(NimbusServicesListError, "No free slots on nimbus services list")
  try:
    createThread(
      services.serviceList[currentIndex].get().threadHandler, serviceHandler, parameters
    )
  except CatchableError as e:
    isShutDownRequired.store(true)
    fatal "error creating service (thread)", msg = e.msg

  info "Created service:", service = services.serviceList[currentIndex].get().name

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

## Service monitoring
proc monitor*(servicesList: NimbusServicesList) =
  info "started service monitoring"

  while isShutDownRequired.load() == false:
    sleep(cNimbusServiceTimeoutMs)

  if isShutDownRequired.load() == true:
    servicesList.joinServices()

  notice "Shutting down now"

## create workers
proc configureService*(
    servicesList: var NimbusServicesList,
    config: var LayerConfig,
    execName: string,
    fun: proc(config: ServiceParameters) {.thread.},
    timeout: uint32 = cNimbusServiceTimeoutMs,
) {.raises: [CatchableError].} =
  var params: ServiceParameters = ServiceParameters(name: execName, layerConfig: config)
  servicesList.addNewService(fun, params, timeout)

# ------
when isMainModule:
  notice "Starting Nimbus"

  ## TODO
  # create a procedure to extract and filter the command
  # line options for each layer
  # here we are adding the "engine-api" option for eth1
  var args: seq[string] = @["--engine-api"]

  var execConfig = makeConfig(@["--engine-api"])
  var beaconConfig = makeBannerAndConfig(
    clientName, versionAsStr, nimBanner, "", [], BeaconNodeConf
  ).valueOr:
    stderr.write error
    quit QuitFailure

  # trustedNodeSync (same  as before)
  if beaconConfig.cmd == BNStartUpCmd.trustedNodeSync:
    let
      nodeSync = LayerConfig(kind: Consensus, consensusConfig: beaconConfig)
      params: ServiceParameters =
        ServiceParameters(name: "trustedNodeSync", layerConfig: nodeSync)

    info " Starting trusted node synchronization"
    consensusWrapper(params)
    quit (0)

  if not (checkAndCreateDataDir(string(beaconConfig.dataDir))):
    quit QuitFailure

  setupFileLimits()

  # setupLogging(config.logLevel, config.logStdout, config.logFile)

  createPidFile(beaconConfig.dataDir.string / "unified.pid")

  var servicesList: NimbusServicesList = NimbusServicesList.new

  ## Graceful shutdown by handling of Ctrl+C signal
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except NimbusServicesListError as exc:
        raiseAssert exc.msg # shouldn't happen

    notice "\nCtrl+C pressed. Shutting down working services"
    isShutDownRequired.store(true)

  setControlCHook(controlCHandler)

  #create and start services
  var
    execution = LayerConfig(kind: Execution, executionConfig: execConfig)
    consensus = LayerConfig(kind: Consensus, consensusConfig: beaconConfig)

  servicesList.configureService(execution, "Execution Layer", executionLayerHandler)
  servicesList.configureService(consensus, "Consensus Layer", consensusLayerHandler)

  #start monitoring
  servicesList.monitor()

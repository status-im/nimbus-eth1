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
  options,
  consensus/consensus_layer,
  execution/execution_layer,
  configs/nimbus_configs,
  #eth2-configs
  beacon_chain/nimbus_binary_common,
  #eth1-configs
  ../nimbus/nimbus_desc

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

## Execution Layer handler
proc executionLayerHandler(parameters: ServiceParameters) {.thread.} =
  info "Started service:", service = parameters.name
  executionLayer(parameters)
  info "\tExited service", service = parameters.name

## Consensus Layer handler
proc consensusLayerHandler(parameters: ServiceParameters) {.thread.} =
  info "Started service:", service = parameters.name

  info "Waiting for execution layer bring up ..."
  consensusLayer(parameters)
  info "\tExit service", service = parameters.name

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
## returns position on services list
proc addService(
    nimbus: var Nimbus,
    serviceHandler: proc(config: ServiceParameters) {.thread.},
    parameters: var ServiceParameters,
    timeout: uint32,
): int =
  #search next available free worker
  var currentIndex = -1
  for i in 0 .. cNimbusMaxServices - 1:
    if nimbus.serviceList[i].isNone:
      nimbus.serviceList[i] =
        some(NimbusService(name: parameters.name, timeoutMs: timeout))
      currentIndex = i
      parameters.name = parameters.name
      break

  if currentIndex < 0:
    raise newException(NimbusServiceError, "No available slots on nimbus services list")

  info "Created service:", service = nimbus.serviceList[currentIndex].get().name

  currentIndex

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

## Block execution and waits for services to finish
proc exitServices*(nimbus: Nimbus) =

  for i in 0 .. cNimbusMaxServices - 1:
    if nimbus.serviceList[i].isSome:
      let thread = nimbus.serviceList[i].get()
      if thread.serviceHandler.running():
        joinThread(thread.serviceHandler)
        nimbus.serviceList[i] = none(NimbusService)
        info "Exited service ", service = thread.name

  notice "Exited all services"

## Service monitoring
proc monitor*(nimbus: Nimbus) =
  info "started service monitoring"

  while isShutDownRequired.load() == false:
    sleep(cNimbusServiceTimeoutMs)

  if isShutDownRequired.load() == true:
    nimbus.exitServices()

  notice "Shutting down now"

## create and configure service
proc startService*(
    nimbus: var Nimbus,
    config: var LayerConfig,
    service: string,
    fun: proc(config: ServiceParameters) {.thread.},
    timeout: uint32 = cNimbusServiceTimeoutMs,
) {.raises: [CatchableError].} =
  var params: ServiceParameters = ServiceParameters(name: service, layerConfig: config)
  let serviceId = nimbus.addService(fun, params, timeout)

  try:
    createThread(nimbus.serviceList[serviceId].get().serviceHandler, fun, params)
  except CatchableError as e:
    fatal "error creating service (thread)", msg = e.msg

  info "Starting service ", service = service

# ------
when isMainModule:
  notice "Starting Nimbus"

  setupFileLimits()

  var nimbus: Nimbus = Nimbus.new

  ## Graceful shutdown by handling of Ctrl+C signal
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except NimbusServiceError as exc:
        raiseAssert exc.msg # shouldn't happen

    notice "\tCtrl+C pressed. Shutting down services"
    isShutDownRequired.store(true)
    nimbus.exitServices()

  setControlCHook(controlCHandler)

  var
    execution = LayerConfig(kind: Execution, executionConfig: NimbusConf())
    consensus = LayerConfig(kind: Consensus, consensusConfig: BeaconNodeConf())

  try:
    nimbus.startService(execution, "Execution Layer", executionLayerHandler)
    nimbus.startService(consensus, "Consensus Layer", consensusLayerHandler)
  except Exception:
    isShutDownRequired.store(true)
    nimbus.exitServices()
    quit QuitFailure

  nimbus.monitor()

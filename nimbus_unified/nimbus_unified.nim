# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
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
  beacon_chain/[conf, conf_common],
  beacon_chain/[beacon_chain_db]

## Constants
const cNimbusMaxTasks* = 5
const cNimbusTaskTimeoutMs* = 5000

## Exceptions
type NimbusTasksError* = object of CatchableError

## Task and associated task information
type NimbusTask* = ref object
  name*: string
  timeoutMs*: uint32
  threadHandler*: Thread[TaskParameters]

## Task manager
type NimbusTasks* = ref object
  taskList*: array[cNimbusMaxTasks, NimbusTask]

## log
logScope:
  topics = "Task manager"

# ------------------------------------------------------------------------------
# Private and helper functions
# ------------------------------------------------------------------------------

## Execution Layer handler
proc executionLayerHandler(parameters: TaskParameters) {.thread.} =
  info "Started task:", task = parameters.name
  while true:
    executionWrapper(parameters)
    if isShutDownRequired.load() == true:
      break
  info "\tExiting task;", task = parameters.name

## Consensus Layer handler
proc consensusLayerHandler(parameters: TaskParameters) {.thread.} =
  info "Started task:", task = parameters.name
  consensusWrapper(parameters)
  info "\tExiting task:", task = parameters.name

## Waits for tasks to finish (joinThreads)
proc joinTasks(tasks: var NimbusTasks) =
  for i in 0 .. cNimbusMaxTasks - 1:
    if not tasks.taskList[i].isNil:
      joinThread(tasks.taskList[i].threadHandler)

  info "\tAll tasks finished"

#TODO: Investigate if this is really needed? and for what purpose?
var gPidFile: string
proc createPidFile(filename: string) {.raises: [IOError].} =
  writeFile filename, $os.getCurrentProcessId()
  gPidFile = filename
  addExitProc (
    proc() =
      discard io2.removeFile(filename)
  )

# ----

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

## adds a new task to nimbus Tasks.
## Note that thread handler passed by argument needs to have the signature: proc foobar(NimbusParameters)
proc addNewTask*(
    tasks: var NimbusTasks,
    timeout: uint32,
    taskHandler: proc(config: TaskParameters) {.thread.},
    parameters: var TaskParameters,
) =
  #search next available worker
  var currentIndex = -1
  for i in 0 .. cNimbusMaxTasks - 1:
    if tasks.taskList[i].isNil:
      tasks.taskList[i] = NimbusTask.new
      tasks.taskList[i].name = parameters.name
      tasks.taskList[i].timeoutMs = timeout
      currentIndex = i
      parameters.name = parameters.name
      break

  if currentIndex < 0:
    raise newException(NimbusTasksError, "No free slots on Nimbus Tasks")
  createThread(tasks.taskList[currentIndex].threadHandler, taskHandler, parameters)
  info "Created task:", task = tasks.taskList[currentIndex].name

## Task monitoring
proc monitor*(tasksList: var NimbusTasks, config: NimbusConfig) =
  info "monitoring tasks"

  while true:
    info "checking tasks ... "

    # -check an atomic (to be created when needed) if it s required to shutdown
    #   this will atomic flag solves:
    # - non responding thread
    # - thread that required shutdown

    sleep(cNimbusTaskTimeoutMs)

## create running workers
proc startTasks*(
    tasksList: var NimbusTasks, configs: NimbusConfig, beaconConfigs: var BeaconNodeConf
) {.raises: [CatchableError].} =
  let

    # TODO: extract configs for each task from NimbusConfig
    # or extract them somewhere else and passs them here
    execName = "Execution Layer"
    consName = "Consensus Layer"
  var
    paramsExecution: TaskParameters = TaskParameters(
      name: execName,
      configs: "task configs extracted from NimbusConfig go here",
      beaconNodeConfigs: beaconConfigs,
    )
    paramsConsensus: TaskParameters = TaskParameters(
      name: execName,
      configs: "task configs extracted from NimbusConfig go here",
      beaconNodeConfigs: beaconConfigs,
    )

  tasksList.addNewTask(cNimbusTaskTimeoutMs, executionLayerHandler, paramsExecution)
  tasksList.addNewTask(cNimbusTaskTimeoutMs, consensusLayerHandler, paramsConsensus)

# ------

when isMainModule:
  info "Starting Nimbus"
  ## TODO
  ## - file limits
  ## - check if we have permissions to create data folder if needed
  ## - setup logging
  ## - read configuration
  ## - implement config reader for all components
  let nimbusConfigs = NimbusConfig()
  var tasksList: NimbusTasks = NimbusTasks.new

  ##TODO: this is an adapted call os the vars required by makeBannerAndConfig
  ##these values need to be read from some config file
  const SPEC_VERSION = "1.5.0-alpha.8"
  const copyrights = "status"
  const nimBanner = "nimbus"
  const clientId = "beacon node"
  var beaconNodeConfig = makeBannerAndConfig(
    clientId, copyrights, nimBanner, SPEC_VERSION, [], BeaconNodeConf
  ).valueOr:
    quit(0)

  tasksList.startTasks(nimbusConfigs, beaconNodeConfig)

  ## Graceful shutdown by handling of Ctrl+C signal
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except NimbusTasksError as exc:
        raiseAssert exc.msg # shouldn't happen

    notice "\nCtrl+C pressed. Shutting down working tasks"

    isShutDownRequired.store(true)
    tasksList.joinTasks()
    notice "Shutting down now"
    quit(0)

  setControlCHook(controlCHandler)
  createPidFile(beaconNodeConfig.databaseDir.string / "unified.pid")
  #start monitoring
  tasksList.monitor(nimbusConfigs)

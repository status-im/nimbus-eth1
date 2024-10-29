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
  beacon_chain/[beacon_chain_db],
  beacon_chain/validators/keystore_management

## Constants
## TODO: evaluate the proposed timeouts with team
const cNimbusMaxTasks* = 5
const cNimbusTaskTimeoutMs* = 5000

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
  executionWrapper(parameters)
  info "\tExiting task;", task = parameters.name

## Consensus Layer handler
proc consensusLayerHandler(parameters: TaskParameters) {.thread.} =
  info "Started task:", task = parameters.name
  consensusWrapper(parameters)
  info "\tExiting task:", task = parameters.name

## Waits for tasks to finish (joinThreads)
proc joinTasks(tasks: var NimbusTasks) =
  warn "Waiting all tasks to finish ... "
  for i in 0 .. cNimbusMaxTasks - 1:
    if not tasks.taskList[i].isNil:
      joinThread(tasks.taskList[i].threadHandler)

  notice "All tasks finished correctly"

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
  try:
    createThread(tasks.taskList[currentIndex].threadHandler, taskHandler, parameters)
  except CatchableError as e:
    # TODO: joinThreads
    fatal "error creating task (thread)", msg = e.msg

  info "Created task:", task = tasks.taskList[currentIndex].name

## Task monitoring
proc monitor*(tasksList: var NimbusTasks, config: NimbusConfig) =
  info "started task monitoring"

  while true:
    info "checking tasks ... "
    if isShutDownRequired.load() == true:
      break
    sleep(cNimbusTaskTimeoutMs)

  tasksList.joinTasks()

## create running workers
proc startTasks*(
    tasksList: var NimbusTasks, configs: NimbusConfig, beaconConfigs: var BeaconNodeConf
) {.raises: [CatchableError].} =
  let

    # TODO: extract configs for each task from NimbusConfig
    # or extract them somewhere else and passs them here.
    # check nimbus_configs annotations.
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
  ## - setup logging
  ## - read configuration (check nimbus_configs file anottations)
  ## - implement config reader for all components
  let nimbusConfigs = NimbusConfig()
  var tasksList: NimbusTasks = NimbusTasks.new

  ##TODO: this is an adapted call os the vars required by makeBannerAndConfig
  ##these values need to be read from some config file
  const SPEC_VERSION = "tbd"
  const copyrights = "status"
  const nimBanner = "nimbus"
  const clientId = "nimbus unified"
  var beaconNodeConfig = makeBannerAndConfig(
    clientId, copyrights, nimBanner, SPEC_VERSION, [], BeaconNodeConf
  ).valueOr:
    stderr.write error
    quit QuitFailure

  #TODO: if we don't add the "db" program crashes on
  if not(checkAndCreateDataDir(string(beaconNodeConfig.dataDir/"db"))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  # TODO: data directory is not created(build/data/shared_holesky_0/db/)
  # and "createPidFile" throws an exception
  # solution: manually create the directory
  createPidFile(beaconNodeConfig.databaseDir.string / "unified.pid")

  ## Graceful shutdown by handling of Ctrl+C signal
  ## TODO: we might need to declare it per thread
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

  #create and start tasks
  tasksList.startTasks(nimbusConfigs, beaconNodeConfig)

  #start monitoring
  tasksList.monitor(nimbusConfigs)

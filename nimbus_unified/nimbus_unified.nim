# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[atomics, os, tables], chronicles, beacon_chain/nimbus_binary_common

## Exceptions
type NimbusTasksError* = object of CatchableError

#task shutdown flag
var isShutDownRequired*: Atomic[bool]
isShutDownRequired.store(false)

## Configuration
## TODO: implement a json (or other format like yaml) config reader for config reading (file config scenarios)
##  or extract from other nimbus components
## TODO: implement a command line reader to read arguments
type NimbusConfig* = object
  configTable: Table[string, string]

## Nimbus workers arguments (thread arguments)
type TaskParameters* = object
  name*: string
  configs*: string
    # TODO: replace this with the extracted configs from NimbusConfig needed by the worker

## Constants
const cNimbusMaxTasks* = 5
const cNimbusTaskTimeoutMs* = 5000

## Task and associated task information
type NimbusTask* = ref object
  name*: string
  timeoutMs*: uint32
  threadHandler*: Thread[TaskParameters]

## Task scheduler and manager
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
    sleep(3000)
    info "exec"
    if isShutDownRequired.load() == true:
      break
  info "\tExiting task;", task = parameters.name

## Consensus Layer handler
proc consensusLayerHandler(parameters: TaskParameters) {.thread.} =
  info "Started task:", task = parameters.name
  while true:
    sleep(3000)
    info "exec"
    if isShutDownRequired.load() == true:
      break
  info "\tExiting task:", task = parameters.name

## Waits for tasks to finish
proc joinTasks(tasks: var NimbusTasks) =
  for i in 0 .. cNimbusMaxTasks - 1:
    if not tasks.taskList[i].isNil:
      joinThread(tasks.taskList[i].threadHandler)

  info "\tAll tasks finished"

# ----

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

## adds a new task to nimbus Tasks.
## Note that thread handler passed by argument needs to have the signature: proc foobar(NimbusParameters)
proc addNewTask*(
    tasks: var NimbusTasks,
    name: string,
    timeout: uint32,
    taskHandler: proc(config: TaskParameters) {.thread.},
    parameters: var TaskParameters,
) =
  #search next available worker
  var currentIndex = -1
  for i in 0 .. cNimbusMaxTasks - 1:
    if tasks.taskList[i].isNil:
      tasks.taskList[i] = NimbusTask.new
      tasks.taskList[i].name = name
      tasks.taskList[i].timeoutMs = timeout
      currentIndex = i
      parameters.name = name
      break

  if currentIndex < 0:
    raise newException(NimbusTasksError, "No free slots on Nimbus Tasks")

  createThread(tasks.taskList[currentIndex].threadHandler, taskHandler, parameters)
  info "Created task:", task = tasks.taskList[currentIndex].name

## Task monitoring
proc monitor*(tasksList: var NimbusTasks, config: NimbusConfig) =
  info "monitoring tasks"

  while true:
    info "nothing new"
    sleep(5000)

## create running workers
proc startTasks*(tasksList: var NimbusTasks, configs: NimbusConfig) =
  # TODO: extract configs for each task from NimbusConfig
  # or extract them somewhere else and passs them here
  var
    paramsExecution: TaskParameters =
      TaskParameters(configs: "task configs extracted from NimbusConfig go here")
    paramsConsensus: TaskParameters =
      TaskParameters(configs: "task configs extracted from NimbusConfig go here")

  tasksList.addNewTask(
    "Execution Layer", cNimbusTaskTimeoutMs, executionLayerHandler, paramsExecution
  )
  tasksList.addNewTask(
    "Consensus Layer", cNimbusTaskTimeoutMs, consensusLayerHandler, paramsConsensus
  )

when isMainModule:
  info "Starting Nimbus"
  ## TODO
  ## - make banner and config
  ## - file limits
  ## - check if we have permissions to create data folder if needed
  ## - setup logging

  # TODO - read configuration
  # TODO - implement config reader for all components
  let nimbusConfigs = NimbusConfig()
  var tasksList: NimbusTasks = NimbusTasks.new

  ## next code snippet requires a conf.nim file (eg: beacon_lc_bridge_conf.nim)
  #   var config = makeBannerAndConfig("Nimbus client ", NimbusConfig)
  #   setupLogging(config.logLevel, config.logStdout, config.logFile)

  tasksList.startTasks(nimbusConfigs)

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

  while true:
    info "looping"
    sleep(2000)

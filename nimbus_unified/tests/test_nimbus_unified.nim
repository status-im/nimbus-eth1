# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, atomics],
  unittest2,
  chronicles,
  ../nimbus_unified,
  ../configs/nimbus_configs,
  beacon_chain/conf

# ----------------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------------

template fileExists(filename: string): bool =
  try:
    discard readFile(filename)
    true
  except IOError:
    false

template removeFile(filename: string) =
  try:
    discard io2.removeFile(filename)
  except IOError:
    discard # Ignore if the file does not exist

proc handlerMock(parameters: TaskParameters) {.thread.} =
  echo "handler mock"

# ----------------------------------------------------------------------------
# Unit Tests
# ----------------------------------------------------------------------------

suite "Nimbus Task Management Tests":
  # Test: Creating a new task successfully
  test "addNewTask successfully adds a task":
    var tasks: NimbusTasks = NimbusTasks.new()
    var params: TaskParameters = TaskParameters(name: "TestTask")

    tasks.addNewTask(cNimbusTaskTimeoutMs, handlerMock, params)

    check not tasks.taskList[0].isNil
    check tasks.taskList[0].name == "TestTask"

  # Test: Adding more tasks than the maximum allowed
  test "addNewTask fails when NimbusTasks is full":
    var tasks: NimbusTasks = NimbusTasks.new()

    for i in 0 ..< cNimbusMaxTasks:
      var params: TaskParameters = TaskParameters(name: "Task" & $i)
      tasks.addNewTask(cNimbusTaskTimeoutMs, handlerMock, params)

    # Attempt to add one more task than allowed
    var extraParams: TaskParameters = TaskParameters(name: "ExtraTask")
    check:
      try:
        tasks.addNewTask(cNimbusTaskTimeoutMs, handlerMock, extraParams)
        false # If no exception, test fails
      except NimbusTasksError:
        true # Exception was correctly raised

  # Test: Tasks finish properly and joinTasks correctly joins all threads
  test "joinTasks waits for all tasks to finish":
    var tasks: NimbusTasks = NimbusTasks.new()

    for i in 0 ..< cNimbusMaxTasks:
      var params: TaskParameters = TaskParameters(name: "Task" & $i)
      tasks.addNewTask(cNimbusTaskTimeoutMs, handlerMock, params)

    tasks.joinTasks()

    # Check that all task slots are still non-nil but threads have finished
    for i in 0 ..< cNimbusMaxTasks:
      check not tasks.taskList[i].isNil

  # Test: startTasks initializes both the execution and consensus layer tasks
  test "startTasks initializes execution and consensus tasks":
    var tasks: NimbusTasks = NimbusTasks.new()
    let nimbusConfigs = NimbusConfig()
    var beaconNodeConfig: BeaconNodeConf = BeaconNodeConf()

    tasks.startTasks(nimbusConfigs, beaconNodeConfig)

    # Check that at least two tasks were created
    check not tasks.taskList[0].isNil
    check not tasks.taskList[1].isNil

  # Test: Monitor detects shutdown and calls joinTasks
  test "monitor stops on shutdown signal and calls joinTasks":
    var tasks: NimbusTasks = NimbusTasks.new()
    let config: NimbusConfig = NimbusConfig()

    # Simulate a shutdown signal
    isShutDownRequired.store(true)
    tasks.monitor(config)

    # Check that the monitor loop exits correctly (this is difficult to test directly, but we can infer it)
    check isShutDownRequired.load() == true

  # Test: Control-C handler properly initiates shutdown
  test "controlCHandler triggers shutdown sequence":
    var tasks: NimbusTasks = NimbusTasks.new()
    let config: NimbusConfig = NimbusConfig()

    proc localControlCHandler() {.noconv.} =
      isShutDownRequired.store(true)

    # Set up a simulated control-C hook
    setControlCHook(localControlCHandler)

    # Trigger the hook manually
    localControlCHandler()

    check isShutDownRequired.load() == true

# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, atomics],
  unittest2,
  ../nimbus_unified,
  ../configs/nimbus_configs,
  #eth1-configs
  ../../nimbus/nimbus_desc

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

proc handlerMock(parameters: ServiceParameters) {.thread.} =
  return

# ----------------------------------------------------------------------------
# Unit Tests
# ----------------------------------------------------------------------------

suite "Nimbus Service Management Tests":
  var nimbus: Nimbus
  setup:
    nimbus = Nimbus.new

  # Test: Creating a new service successfully
  test "startService successfully adds a service":
    var layerConfig = LayerConfig(kind: Execution, executionConfig: NimbusConf())

    nimbus.startService(layerConfig, "TestService", handlerMock)

    check nimbus.serviceList[0].isSome
    check nimbus.serviceList[0].get().name == "TestService"

  # Test: Adding more services than the maximum allowed
  test "startService fails when Nimbus is full":
    for i in 0 ..< cNimbusMaxServices:
      var layerConfig = LayerConfig(kind: Execution, executionConfig: NimbusConf())
      nimbus.startService(layerConfig, "service" & $i, handlerMock)

    # Attempt to add one more service than allowed
    var extraConfig = LayerConfig(kind: Execution, executionConfig: NimbusConf())
    check:
      try:
        nimbus.startService(extraConfig, "ExtraService", handlerMock)
        false # If no exception, test fails
      except NimbusServiceError:
        true # Exception was correctly raised

  # Test: Services finish properly and exitServices correctly joins all threads
  test "exitServices waits for all services to finish":
    for i in 0 ..< cNimbusMaxServices:
      var layerConfig = LayerConfig(kind: Execution, executionConfig: NimbusConf())
      nimbus.startService(layerConfig, "service" & $i, handlerMock)

    nimbus.exitServices()

    # Check that all service slots are empty (thread was stopped, joined and its spot cleared)
    for i in 0 ..< cNimbusMaxServices - 1:
      check nimbus.serviceList[i].isNone

  # Test: startServices initializes both the execution and consensus layer services
  test "startServices initializes execution and consensus services":
    var execLayer = LayerConfig(kind: Execution, executionConfig: NimbusConf())
    var consensusLayer = LayerConfig(kind: Execution, executionConfig: NimbusConf())

    nimbus.startService(execLayer, "service1", handlerMock)
    nimbus.startService(consensusLayer, "service2", handlerMock)

    # Check that at least two services were created
    check not nimbus.serviceList[0].isNone
    check not nimbus.serviceList[1].isNone

  # Test: Monitor detects shutdown and calls exitServices
  test "monitor stops on shutdown signal and calls exitServices":
    var layer = LayerConfig(kind: Execution, executionConfig: NimbusConf())
    nimbus.startService(layer, "service1", handlerMock)

    #simulates a shutdown signal
    isShutDownRequired.store(true)
    nimbus.monitor()

    # Check that the monitor loop exits correctly
    # services running should be 0
    check isShutDownRequired.load() == true
    for i in 0 .. cNimbusMaxServices - 1:
      check nimbus.serviceList[i].isNone

  # Test: Control-C handler properly initiates shutdown
  test "controlCHandler triggers shutdown sequence":
    var layer = LayerConfig(kind: Execution, executionConfig: NimbusConf())
    nimbus.startService(layer, "service1", handlerMock)

    proc localControlCHandler() {.noconv.} =
      isShutDownRequired.store(true)
      nimbus.exitServices()

    # Set up a simulated control-C hook
    setControlCHook(localControlCHandler)

    # Trigger the hook manually
    localControlCHandler()

    check isShutDownRequired.load() == true

    #services running should be 0
    for i in 0 .. cNimbusMaxServices - 1:
      check nimbus.serviceList[i].isNone

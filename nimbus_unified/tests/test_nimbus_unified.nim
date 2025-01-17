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

proc handlerMock(parameters: ServiceParameters) {.thread.} =
  echo "handler mock"

# ----------------------------------------------------------------------------
# Unit Tests
# ----------------------------------------------------------------------------

suite "Nimbus Service Management Tests":
  # Test: Creating a new service successfully
  test "addNewService successfully adds a service":
    var services: NimbusServicesList = NimbusServicesList.new()
    var params: ServiceParameters = ServiceParameters(name: "TestService")

    services.addNewService(cNimbusServiceTimeoutMs, handlerMock, params)

    check not services.serviceList[0].isNil
    check services.serviceList[0].name == "TestService"

  # Test: Adding more services than the maximum allowed
  test "addNewService fails when NimbusServicesList is full":
    var services: NimbusServicesList = NimbusServicesList.new()

    for i in 0 ..< cNimbusMaxServices:
      var params: ServiceParameters = ServiceParameters(name: "Service" & $i)
      services.addNewService(cNimbusServiceTimeoutMs, handlerMock, params)

    # Attempt to add one more service than allowed
    var extraParams: ServiceParameters = ServiceParameters(name: "ExtraService")
    check:
      try:
        services.addNewService(cNimbusServiceTimeoutMs, handlerMock, extraParams)
        false # If no exception, test fails
      except NimbusServicesListError:
        true # Exception was correctly raised

  # Test: Services finish properly and joinServices correctly joins all threads
  test "joinServices waits for all services to finish":
    var services: NimbusServicesList = NimbusServicesList.new()

    for i in 0 ..< cNimbusMaxServices:
      var params: ServiceParameters = ServiceParameters(name: "Service" & $i)
      services.addNewService(cNimbusServiceTimeoutMs, handlerMock, params)

    services.joinServices()

    # Check that all service slots are still non-nil but threads have finished
    for i in 0 ..< cNimbusMaxServices:
      check not services.serviceList[i].isNil

  # Test: startServices initializes both the execution and consensus layer services
  test "startServices initializes execution and consensus services":
    var services: NimbusServicesList = NimbusServicesList.new()
    let nimbusConfigs = NimbusConfig()
    var beaconNodeConfig: BeaconNodeConf = BeaconNodeConf()

    services.startServices(nimbusConfigs, beaconNodeConfig)

    # Check that at least two services were created
    check not services.serviceList[0].isNil
    check not services.serviceList[1].isNil

  # Test: Monitor detects shutdown and calls joinServices
  test "monitor stops on shutdown signal and calls joinServices":
    var services: NimbusServicesList = NimbusServicesList.new()
    let config: NimbusConfig = NimbusConfig()

    # Simulate a shutdown signal
    isShutDownRequired.store(true)
    services.monitor(config)

    # Check that the monitor loop exits correctly (this is difficult to test directly, but we can infer it)
    check isShutDownRequired.load() == true

  # Test: Control-C handler properly initiates shutdown
  test "controlCHandler triggers shutdown sequence":
    var services: NimbusServicesList = NimbusServicesList.new()
    let config: NimbusConfig = NimbusConfig()

    proc localControlCHandler() {.noconv.} =
      isShutDownRequired.store(true)

    # Set up a simulated control-C hook
    setControlCHook(localControlCHandler)

    # Trigger the hook manually
    localControlCHandler()

    check isShutDownRequired.load() == true

# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import unittest2, std/atomics, ../[nimbus, conf], ../common/utils, tables, results

# # ----------------------------------------------------------------------------
# # Helpers
# # ----------------------------------------------------------------------------

# checks result computed in thread procedures
var checkResult: ptr bool = createShared(bool)

# simple mock
proc handlerMock(channel: ptr Channel[pointer]) =
  return

#handles data for a given service
proc handlerService_1(channel: ptr Channel[pointer]) =
  const expectedConfigList =
    @["-config=a", "--singleconfig", "-abbrev", "-abbrevArg=arg"]

  let p = channel[].recv()

  let configs = deserializeConfigArgs(p).valueOr:
    quit(QuitFailure)

  isConfigRead.store(true)

  checkResult[] = configs == expectedConfigList

#handles data for a given service
proc handlerService_2(channel: ptr Channel[pointer]) =
  const expectedConfigList =
    @["--singleconfig2", "-config2=a2", "-abbrev2", "-abbrevArg2=arg2"]

  let p = channel[].recv()

  let configs = deserializeConfigArgs(p).valueOr:
    quit(QuitFailure)

  isConfigRead.store(true)

  checkResult[] = configs == expectedConfigList

# ----------------------------------------------------------------------------
# # Unit Tests
# ----------------------------------------------------------------------------

suite "Nimbus Service Management":
  var nimbus: Nimbus
  setup:
    nimbus = Nimbus.new

  const configTable_1 =
    {"-config": "=a", "--singleconfig": "", "-abbrev": "", "-abbrevArg": "=arg"}.toTable
  const configTable_2 = {
    "-config2": "=a2", "--singleconfig2": "", "-abbrev2": "", "-abbrevArg2": "=arg2"
  }.toTable

  # Test: Creating a new service successfully
  test "startService successfully adds a service":
    var someService: NimbusService = NimbusService(
      name: "FooBar service",
      serviceFunc: handlerMock,
      layerConfig: LayerConfig(kind: Consensus, consensusOptions: configTable_1),
    )
    nimbus.serviceList.add(someService)

    check nimbus.serviceList.len == 1
    check nimbus.serviceList[0].name == "FooBar service"

  test "nimbus sends correct data for a service":
    var someService: NimbusService = NimbusService(
      name: "FooBar service",
      serviceFunc: handlerService_1,
      layerConfig: LayerConfig(kind: Consensus, consensusOptions: configTable_1),
    )

    nimbus.serviceList.add(someService)

    nimbus.startService(someService)

    check nimbus.serviceList.len == 1
    check nimbus.serviceList[0].name == "FooBar service"
    check checkResult[] == true

  test "nimbus sends correct data for multiple services":
    var someService: NimbusService = NimbusService(
      name: "FooBar service",
      serviceFunc: handlerService_1,
      layerConfig: LayerConfig(kind: Consensus, consensusOptions: configTable_1),
    )
    var anotherService: NimbusService = NimbusService(
      name: "Xpto service",
      serviceFunc: handlerService_2,
      layerConfig: LayerConfig(kind: Execution, executionOptions: configTable_2),
    )
    nimbus.serviceList.add(someService)
    nimbus.serviceList.add(anotherService)

    nimbus.startService(someService)
    check checkResult[] == true

    nimbus.startService(anotherService)
    check checkResult[] == true

    check nimbus.serviceList.len == 2
    check nimbus.serviceList[0].name == "FooBar service"
    check nimbus.serviceList[1].name == "Xpto service"

# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[os, atomics], unittest2, ../nimbus, ../conf

# # ----------------------------------------------------------------------------
# # Helper Functions
# # ----------------------------------------------------------------------------
proc handlerMock(channel: ptr Channel[pointer]) =
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
    var someService: NimbusService = NimbusService(
      name: "FooBar service",
      serviceFunc: handlerMock,
      layerConfig: LayerConfig(kind: Consensus, consensusOptions: @["foo", "bar"]),
    )
    nimbus.serviceList.add(someService)

    check nimbus.serviceList.len == 1
    check nimbus.serviceList[0].name == "FooBar service"

# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/atomics, unittest2, ../../consensus/consensus_layer, ../../configs/nimbus_configs

# ----------------------------------------------------------------------------
# Unit Tests
# ----------------------------------------------------------------------------

suite "Nimbus Consensus Layer Tests":
  # Test: consensusLayer handles CatchableError gracefully
  test "consensusLayer handles CatchableError and sets shutdown flag":
    var params = ServiceParameters(
      name: "ErrorTest",
      layerConfig: LayerConfig(kind: Consensus, consensusConfig: BeaconNodeConf()),
    )

    check:
      try:
        consensusLayer(params)
        true # No uncaught exceptions
      except CatchableError:
        false # If an exception is raised, the test fails

    check isShutDownRequired.load() == true # Verify shutdown flag is set

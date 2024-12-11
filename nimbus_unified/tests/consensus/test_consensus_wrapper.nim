# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/atomics,
  unittest2,
  beacon_chain/[conf, conf_common],
  ../../consensus/consensus_wrapper,
  ../../version

# ----------------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------------
proc createBeaconNodeConf(): BeaconNodeConf =
  var conf = makeBannerAndConfig(
    clientName, versionAsStr, nimBanner, "", [], BeaconNodeConf
  ).valueOr:
    stderr.write error
    quit QuitFailure

  conf

# ----------------------------------------------------------------------------
# Unit Tests
# ----------------------------------------------------------------------------

suite "Nimbus Consensus Wrapper Tests":
  # Test: handleStartingOption with BNStartUpCmd.trustedNodeSync and missing blockId
  test "handleStartingOption errors on missing blockId with trustedNodeSync command":
    var config = createBeaconNodeConf()
    config.cmd = BNStartUpCmd.trustedNodeSync
    config.blockId = some("blockId") # Simulate missing blockId

    check:
      try:
        config.handleStartingOption()
        false # If no exception, test fails
      except CatchableError:
        true # Correctly raised an error

  # Test: handleStartingOption with an unknown command
  test "handleStartingOption handles unknown command gracefully":
    var config = createBeaconNodeConf()
    config.cmd = BNStartUpCmd(cast[BNStartUpCmd](999)) # Invalid command enum

    check:
      try:
        config.handleStartingOption()
        true # No exception should be raised
      except CatchableError:
        false # If an exception is raised, the test fails

  # Test: consensusWrapper handles CatchableError gracefully
  test "consensusWrapper handles CatchableError and sets shutdown flag":
    var params: TaskParameters = TaskParameters(
      name: "ErrorTest",
      beaconNodeConfigs: BeaconNodeConf(cmd: BNStartUpCmd(cast[BNStartUpCmd](999))),
        # Invalid command enum), # Invalid command
    )

    check:
      try:
        consensusWrapper(params)
        true # No uncaught exceptions
      except CatchableError:
        false # If an exception is raised, the test fails

    check isShutDownRequired.load() == true # Verify shutdown flag is set

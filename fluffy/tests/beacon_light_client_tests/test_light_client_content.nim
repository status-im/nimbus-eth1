# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  stint,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  ../../network/beacon_light_client/light_client_content,
  ./light_client_test_data

suite "Test light client contentEncodings":
  var forks: ForkDigests
  forks.phase0 = ForkDigest([0'u8, 0, 0, 1])
  forks.altair = ForkDigest([0'u8, 0, 0, 2])
  forks.bellatrix = ForkDigest([0'u8, 0, 0, 3])
  forks.capella = ForkDigest([0'u8, 0, 0, 4])
  forks.sharding = ForkDigest([0'u8, 0, 0, 5])

  test "Light client bootstrap correct":
    let
      bootstrap = SSZ.decode(bootStrapBytes, altair.LightClientBootstrap)
      encodedForked = encodeBootstrapForked(forks.altair, bootstrap)
      decodedResult = decodeBootstrapForked(forks, encodedForked)

    check:
      decodedResult.isOk()
      decodedResult.get() == bootstrap

  test "Light client bootstrap failures":
    let
      bootstrap = SSZ.decode(bootStrapBytes, altair.LightClientBootstrap)
      encodedTooEarlyFork = encodeBootstrapForked(forks.phase0, bootstrap)
      encodedUnknownFork = encodeBootstrapForked(
        ForkDigest([0'u8, 0, 0, 6]), bootstrap
      )

    check:
      decodeBootstrapForked(forks, @[]).isErr()
      decodeBootstrapForked(forks, encodedTooEarlyFork).isErr()
      decodeBootstrapForked(forks, encodedUnknownFork).isErr()




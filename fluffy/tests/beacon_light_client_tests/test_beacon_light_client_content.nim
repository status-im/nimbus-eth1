# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  ../../network/beacon_light_client/beacon_light_client_content,
  "."/[light_client_test_data, beacon_light_client_test_helpers]

suite "Beacon Light Client Content Encodings":
  let forkDigests = testForkDigests

  test "LightClientBootstrap":
    let
      altairData = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      bootstrap = ForkedLightClientBootstrap(
        kind: LightClientDataFork.Altair, altairData: altairData)

      encoded = encodeForkedLightClientObject(bootstrap, forkDigests.altair)
      decoded = decodeLightClientBootstrapForked(forkDigests, encoded)

    check:
      decoded.isOk()
      decoded.get().kind == LightClientDataFork.Altair
      decoded.get().altairData == altairData

  test "LightClientUpdate":
    let
      altairData = SSZ.decode(lightClientUpdateBytes, altair.LightClientUpdate)
      update = ForkedLightClientUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData)

      encoded = encodeForkedLightClientObject(update, forkDigests.altair)
      decoded = decodeLightClientUpdateForked(forkDigests, encoded)

    check:
      decoded.isOk()
      decoded.get().kind == LightClientDataFork.Altair
      decoded.get().altairData == altairData

  test "LightClientUpdateList":
    let
      altairData = SSZ.decode(lightClientUpdateBytes, altair.LightClientUpdate)
      update = ForkedLightClientUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData)
      updateList = @[update, update]

      encoded = encodeLightClientUpdatesForked(forkDigests.altair, updateList)
      decoded = decodeLightClientUpdatesByRange(forkDigests, encoded)

    check:
      decoded.isOk()
      decoded.get().asSeq()[0].altairData == updateList[0].altairData
      decoded.get().asSeq()[1].altairData == updateList[1].altairData

  test "LightClientFinalityUpdate":
    let
      altairData = SSZ.decode(
        lightClientFinalityUpdateBytes, altair.LightClientFinalityUpdate)
      update = ForkedLightClientFinalityUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData)

      encoded = encodeForkedLightClientObject(update, forkDigests.altair)
      decoded = decodeLightClientFinalityUpdateForked(forkDigests, encoded)

    check:
      decoded.isOk()
      decoded.get().kind == LightClientDataFork.Altair
      decoded.get().altairData == altairData

  test "LightClientOptimisticUpdate":
    let
      altairData = SSZ.decode(
        lightClientOptimisticUpdateBytes, altair.LightClientOptimisticUpdate)
      update = ForkedLightClientOptimisticUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData)

      encoded = encodeForkedLightClientObject(update, forkDigests.altair)
      decoded = decodeLightClientOptimisticUpdateForked(forkDigests, encoded)

    check:
      decoded.isOk()
      decoded.get().kind == LightClientDataFork.Altair
      decoded.get().altairData == altairData

  test "Invalid LightClientBootstrap":
    let
      altairData = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      # TODO: This doesn't make much sense with current API
      bootstrap = ForkedLightClientBootstrap(
        kind: LightClientDataFork.Altair, altairData: altairData)

      encodedTooEarlyFork = encodeForkedLightClientObject(
        bootstrap, forkDigests.phase0)
      encodedUnknownFork = encodeForkedLightClientObject(
        bootstrap, ForkDigest([0'u8, 0, 0, 6]))

    check:
      decodeLightClientBootstrapForked(forkDigests, @[]).isErr()
      decodeLightClientBootstrapForked(forkDigests, encodedTooEarlyFork).isErr()
      decodeLightClientBootstrapForked(forkDigests, encodedUnknownFork).isErr()

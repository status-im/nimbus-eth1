# Nimbus - Portal Network
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  testutils/unittests,
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  beacon_chain/spec/helpers,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/beacon/[beacon_init_loader, beacon_light_client],
  "."/[light_client_test_data, beacon_test_helpers]

procSuite "Beacon Light Client":
  let rng = newRng()

  proc headerCallback(
      q: AsyncQueue[ForkedLightClientHeader]
  ): LightClientHeaderCallback =
    return (
      proc(
          lightClient: LightClient, finalizedHeader: ForkedLightClientHeader
      ) {.gcsafe, raises: [].} =
        try:
          q.putNoWait(finalizedHeader)
        except AsyncQueueFullError as exc:
          raiseAssert(exc.msg)
    )

  asyncTest "Start and retrieve bootstrap":
    let
      finalizedHeaders = newAsyncQueue[ForkedLightClientHeader]()
      optimisticHeaders = newAsyncQueue[ForkedLightClientHeader]()
      # Test data is retrieved from mainnet
      networkData = loadNetworkData("mainnet")
      altairData = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      bootstrap = ForkedLightClientBootstrap(
        kind: LightClientDataFork.Altair, altairData: altairData
      )
      bootstrapBlockRoot = hash_tree_root(altairData.header)
      lcNode1 = newLCNode(rng, 20302, networkData, Opt.some(bootstrapBlockRoot))
      lcNode2 = newLCNode(rng, 20303, networkData, Opt.some(bootstrapBlockRoot))

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      bootstrapKey = LightClientBootstrapKey(blockHash: bootstrapBlockRoot)
      bootstrapContentKey = ContentKey(
        contentType: lightClientBootstrap, lightClientBootstrapKey: bootstrapKey
      )

      bootstrapContentKeyEncoded = encode(bootstrapContentKey)
      bootstrapContentId = toContentId(bootstrapContentKeyEncoded)

    lcNode2.portalProtocol().storeContent(
      bootstrapContentKeyEncoded,
      bootstrapContentId,
      encodeForkedLightClientObject(bootstrap, networkData.forks.altair),
    )

    let lc = LightClient.new(
      lcNode1.beaconNetwork, rng, networkData, LightClientFinalizationMode.Optimistic
    )

    lc.onFinalizedHeader = headerCallback(finalizedHeaders)
    lc.onOptimisticHeader = headerCallback(optimisticHeaders)

    # When running start the beacon light client will first try to retrieve the
    # bootstrap for given trustedBlockRoot
    lc.start()

    # Wait until the beacon light client retrieves the bootstrap. Upon receiving
    # the bootstrap both onFinalizedHeader and onOptimisticHeader callbacks
    # will be called.
    let
      receivedFinalHeader = await finalizedHeaders.get()
      receivedOptimisticHeader = await optimisticHeaders.get()

    check:
      hash_tree_root(receivedFinalHeader.altairData) == bootstrapBlockRoot
      hash_tree_root(receivedOptimisticHeader.altairData) == bootstrapBlockRoot

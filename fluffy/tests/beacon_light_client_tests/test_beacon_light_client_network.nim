# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  testutils/unittests, chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  ../../network/wire/portal_protocol,
  ../../network/beacon_light_client/beacon_light_client_network,
  "."/[light_client_test_data, beacon_light_client_test_helpers]

procSuite "Beacon Light Client Content Network":
  let rng = newRng()

  asyncTest "Get bootstrap by trusted block hash":
    let
      lcNode1 = newLCNode(rng, 20302)
      lcNode2 = newLCNode(rng, 20303)
      forkDigests = testForkDigests

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      altairData = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      bootstrap = ForkedLightClientBootstrap(
        kind: LightClientDataFork.Altair, altairData: altairData)
      bootstrapHeaderHash = hash_tree_root(altairData.header)
      bootstrapKey = LightClientBootstrapKey(
        blockHash: bootstrapHeaderHash
      )
      bootstrapContentKey = ContentKey(
        contentType: lightClientBootstrap,
        lightClientBootstrapKey: bootstrapKey
      )

      bootstrapContentKeyEncoded = encode(bootstrapContentKey)
      bootstrapContentId = toContentId(bootstrapContentKeyEncoded)

    lcNode2.portalProtocol().storeContent(
      bootstrapContentKeyEncoded,
      bootstrapContentId,
      encodeForkedLightClientObject(bootstrap, forkDigests.altair)
    )

    let bootstrapFromNetworkResult =
      await lcNode1.lightClientNetwork.getLightClientBootstrap(
        bootstrapHeaderHash
      )

    check:
      bootstrapFromNetworkResult.isOk()
      bootstrapFromNetworkResult.get().altairData == bootstrap.altairData

    await lcNode1.stop()
    await lcNode2.stop()

  asyncTest "Get latest optimistic and finality updates":
    let
      lcNode1 = newLCNode(rng, 20302)
      lcNode2 = newLCNode(rng, 20303)
      forkDigests = testForkDigests

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      finalityUpdateData = SSZ.decode(
        lightClientFinalityUpdateBytes, altair.LightClientFinalityUpdate)
      finalityUpdate = ForkedLightClientFinalityUpdate(
        kind: LightClientDataFork.Altair, altairData: finalityUpdateData)
      finalizedHeaderSlot = finalityUpdateData.finalized_header.beacon.slot
      finalizedOptimisticHeaderSlot =
        finalityUpdateData.attested_header.beacon.slot

      optimisticUpdateData = SSZ.decode(
        lightClientOptimisticUpdateBytes, altair.LightClientOptimisticUpdate)
      optimisticUpdate = ForkedLightClientOptimisticUpdate(
        kind: LightClientDataFork.Altair, altairData: optimisticUpdateData)
      optimisticHeaderSlot = optimisticUpdateData.attested_header.beacon.slot

      finalityUpdateKey = finalityUpdateContentKey(
        distinctBase(finalizedHeaderSlot),
        distinctBase(finalizedOptimisticHeaderSlot)
      )
      finalityKeyEnc = encode(finalityUpdateKey)
      finalityUpdateId = toContentId(finalityKeyEnc)

      optimistUpdateKey = optimisticUpdateContentKey(
        distinctBase(optimisticHeaderSlot))
      optimisticKeyEnc = encode(optimistUpdateKey)
      optimisticUpdateId = toContentId(optimisticKeyEnc)


    # This silently assumes that peer stores only one latest update, under
    # the contentId coresponding to latest update content key
    lcNode2.portalProtocol().storeContent(
      finalityKeyEnc,
      finalityUpdateId,
      encodeForkedLightClientObject(finalityUpdate, forkDigests.altair)
    )

    lcNode2.portalProtocol().storeContent(
      optimisticKeyEnc,
      optimisticUpdateId,
      encodeForkedLightClientObject(optimisticUpdate, forkDigests.altair)
    )

    let
      finalityResult =
        await lcNode1.lightClientNetwork.getLightClientFinalityUpdate(
          distinctBase(finalizedHeaderSlot) - 1,
          distinctBase(finalizedOptimisticHeaderSlot) - 1
        )
      optimisticResult =
        await lcNode1.lightClientNetwork.getLightClientOptimisticUpdate(
          distinctBase(optimisticHeaderSlot) - 1
        )

    check:
      finalityResult.isOk()
      optimisticResult.isOk()
      finalityResult.get().altairData == finalityUpdate.altairData
      optimisticResult.get().altairData == optimisticUpdate.altairData

    await lcNode1.stop()
    await lcNode2.stop()

  asyncTest "Get range of light client updates":
    let
      lcNode1 = newLCNode(rng, 20302)
      lcNode2 = newLCNode(rng, 20303)
      forkDigests = testForkDigests

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      altairData1 = SSZ.decode(lightClientUpdateBytes, altair.LightClientUpdate)
      altairData2 = SSZ.decode(lightClientUpdateBytes1, altair.LightClientUpdate)
      update1 = ForkedLightClientUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData1)
      update2 = ForkedLightClientUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData2)
      updates = @[update1, update2]
      content = encodeLightClientUpdatesForked(forkDigests.altair, updates)
      startPeriod =
        altairData1.attested_header.beacon.slot.sync_committee_period
      contentKey = ContentKey(
        contentType: lightClientUpdate,
        lightClientUpdateKey: LightClientUpdateKey(
          startPeriod: startPeriod.uint64,
          count: uint64(2)
        )
      )
      contentKeyEncoded = encode(contentKey)
      contentId = toContentId(contentKey)

    lcNode2.portalProtocol().storeContent(
      contentKeyEncoded,
      contentId,
      content
    )

    let updatesResult =
      await lcNode1.lightClientNetwork.getLightClientUpdatesByRange(
        startPeriod,
        uint64(2)
      )

    check:
      updatesResult.isOk()

    let updatesFromPeer = updatesResult.get()

    check:
      updatesFromPeer.asSeq()[0].altairData == updates[0].altairData
      updatesFromPeer.asSeq()[1].altairData == updates[1].altairData

    await lcNode1.stop()
    await lcNode2.stop()

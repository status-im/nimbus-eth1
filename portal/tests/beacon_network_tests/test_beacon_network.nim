# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  testutils/unittests,
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/spec/forks,
  # Test helpers
  beacon_chain /../ tests/testblockutil,
  beacon_chain /../ tests/mocking/mock_genesis,
  beacon_chain /../ tests/consensus_spec/fixtures_utils,
  ../../network/wire/portal_protocol,
  ../../network/beacon/
    [beacon_network, beacon_init_loader, beacon_chain_historical_summaries],
  "."/[light_client_test_data, beacon_test_helpers]

procSuite "Beacon Network":
  let rng = newRng()

  asyncTest "Get bootstrap by trusted block hash":
    let
      networkData = loadNetworkData("mainnet")
      lcNode1 = newLCNode(rng, 20302, networkData)
      lcNode2 = newLCNode(rng, 20303, networkData)
      forkDigests = (newClone networkData.forks)[]

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      altairData = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      bootstrap = ForkedLightClientBootstrap(
        kind: LightClientDataFork.Altair, altairData: altairData
      )
      bootstrapHeaderHash = hash_tree_root(altairData.header)
      bootstrapKey = LightClientBootstrapKey(blockHash: bootstrapHeaderHash)
      bootstrapContentKey = ContentKey(
        contentType: lightClientBootstrap, lightClientBootstrapKey: bootstrapKey
      )

      bootstrapContentKeyEncoded = encode(bootstrapContentKey)
      bootstrapContentId = toContentId(bootstrapContentKeyEncoded)

    lcNode2.portalProtocol().storeContent(
      bootstrapContentKeyEncoded,
      bootstrapContentId,
      encodeForkedLightClientObject(bootstrap, forkDigests.altair),
    )

    let bootstrapFromNetworkResult =
      await lcNode1.beaconNetwork.getLightClientBootstrap(bootstrapHeaderHash)

    check:
      bootstrapFromNetworkResult.isOk()
      bootstrapFromNetworkResult.get().altairData == bootstrap.altairData

    await lcNode1.stop()
    await lcNode2.stop()

  asyncTest "Get latest optimistic and finality updates":
    let
      networkData = loadNetworkData("mainnet")
      lcNode1 = newLCNode(rng, 20302, networkData)
      lcNode2 = newLCNode(rng, 20303, networkData)
      forkDigests = (newClone networkData.forks)[]

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      finalityUpdateData =
        SSZ.decode(lightClientFinalityUpdateBytes, altair.LightClientFinalityUpdate)
      finalityUpdate = ForkedLightClientFinalityUpdate(
        kind: LightClientDataFork.Altair, altairData: finalityUpdateData
      )
      finalizedHeaderSlot = finalityUpdateData.finalized_header.beacon.slot
      finalizedOptimisticHeaderSlot = finalityUpdateData.attested_header.beacon.slot

      optimisticUpdateData =
        SSZ.decode(lightClientOptimisticUpdateBytes, altair.LightClientOptimisticUpdate)
      optimisticUpdate = ForkedLightClientOptimisticUpdate(
        kind: LightClientDataFork.Altair, altairData: optimisticUpdateData
      )
      optimisticHeaderSlot = optimisticUpdateData.signature_slot

      finalityUpdateKey = finalityUpdateContentKey(distinctBase(finalizedHeaderSlot))
      finalityKeyEnc = encode(finalityUpdateKey)
      finalityUpdateId = toContentId(finalityKeyEnc)

      optimisticUpdateKey =
        optimisticUpdateContentKey(distinctBase(optimisticHeaderSlot))
      optimisticKeyEnc = encode(optimisticUpdateKey)
      optimisticUpdateId = toContentId(optimisticKeyEnc)

    # This silently assumes that peer stores only one latest update, under
    # the contentId coresponding to latest update content key
    lcNode2.portalProtocol().storeContent(
      finalityKeyEnc,
      finalityUpdateId,
      encodeForkedLightClientObject(finalityUpdate, forkDigests.altair),
    )

    lcNode2.portalProtocol().storeContent(
      optimisticKeyEnc,
      optimisticUpdateId,
      encodeForkedLightClientObject(optimisticUpdate, forkDigests.altair),
    )

    let
      finalityResult = await lcNode1.beaconNetwork.getLightClientFinalityUpdate(
        distinctBase(finalizedHeaderSlot)
      )
      optimisticResult = await lcNode1.beaconNetwork.getLightClientOptimisticUpdate(
        distinctBase(optimisticHeaderSlot)
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
      networkData = loadNetworkData("mainnet")
      lcNode1 = newLCNode(rng, 20302, networkData)
      lcNode2 = newLCNode(rng, 20303, networkData)
      forkDigests = (newClone networkData.forks)[]

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      altairData1 = SSZ.decode(lightClientUpdateBytes, altair.LightClientUpdate)
      altairData2 = SSZ.decode(lightClientUpdateBytes1, altair.LightClientUpdate)
      update1 = ForkedLightClientUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData1
      )
      update2 = ForkedLightClientUpdate(
        kind: LightClientDataFork.Altair, altairData: altairData2
      )
      updates = ForkedLightClientUpdateList.init(@[update1, update2])
      content =
        encodeLightClientUpdatesForked(updates, forkDigests, networkData.metadata.cfg)
      startPeriod = altairData1.attested_header.beacon.slot.sync_committee_period
      contentKey = ContentKey(
        contentType: lightClientUpdate,
        lightClientUpdateKey:
          LightClientUpdateKey(startPeriod: startPeriod.uint64, count: uint64(2)),
      )
      contentKeyEncoded = encode(contentKey)
      contentId = toContentId(contentKey)

    lcNode2.portalProtocol().storeContent(contentKeyEncoded, contentId, content)

    let updatesResult =
      await lcNode1.beaconNetwork.getLightClientUpdatesByRange(startPeriod, uint64(2))

    check:
      updatesResult.isOk()

    let updatesFromPeer = updatesResult.get()

    check:
      updatesFromPeer.asSeq()[0].altairData == updates[0].altairData
      updatesFromPeer.asSeq()[1].altairData == updates[1].altairData

    await lcNode1.stop()
    await lcNode2.stop()

  asyncTest "Get HistoricalSummaries":
    let
      cfg = genesisTestRuntimeConfig(ConsensusFork.Electra)
      state = newClone(initGenesisState(cfg = cfg))
      networkData = loadNetworkData("mainnet")
      forkDigests = (newClone networkData.forks)[]

    var cache = StateCache()

    var blocks: seq[electra.SignedBeaconBlock]
    # Note:
    # Adding 8192 blocks. First block is genesis block and not one of these.
    # Then one extra block is needed to get the historical summaries, block
    # roots and state roots processed.
    # index i = 0 is second block.
    # index i = 8190 is 8192th block and last one that is part of the first
    # historical root
    for i in 0 ..< SLOTS_PER_HISTORICAL_ROOT:
      blocks.add(addTestBlock(state[], cache, cfg = cfg).electraData)

    let (content, slot, root) = withState(state[]):
      when consensusFork >= ConsensusFork.Electra:
        let historical_summaries = forkyState.data.historical_summaries
        let res = buildProof(state[])
        check res.isOk()
        let
          proof = res.get()

          historicalSummariesWithProof = HistoricalSummariesWithProof(
            epoch: epoch(forkyState.data.slot),
            historical_summaries: historical_summaries,
            proof: proof,
          )

          # Note that this is not the slot deduced forkDigest, as that one would
          # cause issues for this custom chain.
          # TODO: If we were to encode the historical summaries in the db code
          # it would fail due to slot based fork digest until we allow for
          # custom networks.
          forkDigest = atConsensusFork(forkDigests, consensusFork)

          content = encodeSsz(historicalSummariesWithProof, forkDigest)

        (content, forkyState.data.slot, forkyState.root)
      else:
        raiseAssert("Not implemented pre-Electra")
    let
      lcNode1 = newLCNode(rng, 20302, networkData)
      lcNode2 = newLCNode(rng, 20303, networkData)

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      contentKeyEncoded =
        historicalSummariesContentKey(epoch(slot).distinctBase()).encode()
      contentId = toContentId(contentKeyEncoded)

    lcNode2.portalProtocol().storeContent(contentKeyEncoded, contentId, content)

    block:
      let res = await lcNode1.beaconNetwork.getHistoricalSummaries(epoch(slot))
      # Should fail as it cannot validate
      check res.isErr()

    block:
      # Add a (fake) finality update but with correct slot and state root
      # so that node 1 can do the validation of the historical summaries.
      let
        dummyFinalityUpdate = electra.LightClientFinalityUpdate(
          finalized_header: electra.LightClientHeader(
            beacon: BeaconBlockHeader(slot: slot, state_root: root)
          )
        )
        finalityUpdateForked = ForkedLightClientFinalityUpdate(
          kind: LightClientDataFork.Electra, electraData: dummyFinalityUpdate
        )
        forkDigest = forkDigestAtEpoch(forkDigests, epoch(slot), cfg)
        content = encodeFinalityUpdateForked(forkDigest, finalityUpdateForked)
        contentKey = finalityUpdateContentKey(slot.distinctBase())
        contentKeyEncoded = encode(contentKey)
        contentId = toContentId(contentKeyEncoded)

      lcNode1.portalProtocol().storeContent(contentKeyEncoded, contentId, content)

    block:
      let res = await lcNode1.beaconNetwork.getHistoricalSummaries(epoch(slot))
      check:
        res.isOk()
        withState(state[]):
          when consensusFork >= ConsensusFork.Electra:
            res.get() == forkyState.data.historical_summaries
          else:
            false

    await lcNode1.stop()
    await lcNode2.stop()

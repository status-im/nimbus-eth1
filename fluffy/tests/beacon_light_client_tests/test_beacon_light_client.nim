# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/options,
  testutils/unittests, chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  eth/common/eth_types_rlp,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  beacon_chain/spec/helpers,
  beacon_chain/beacon_clock,
  beacon_chain/conf,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/beacon_light_client/[
    light_client_content,
    beacon_light_client
  ],
  "."/[light_client_test_data, light_client_test_helpers]

procSuite "Portal Light client":
  let rng = newRng()

  proc headerCallback(q: AsyncQueue[BeaconBlockHeader]): LightClientHeaderCallback =
    return (
      proc (lightClient: LightClient, finalizedHeader: BeaconBlockHeader) {.gcsafe, raises: [].} =
        try:
          q.putNoWait(finalizedHeader)
        except AsyncQueueFullError as exc:
          raiseAssert(exc.msg)
    )

  proc loadMainnetData(): Eth2NetworkMetadata =
    try:
      return loadEth2Network(some("mainnet"))
    except CatchableError as exc:
      raiseAssert(exc.msg)

  asyncTest "Start and retrieve bootstrap":
    let
      finalHeaders = newAsyncQueue[BeaconBlockHeader]()
      optimisticHeaders = newAsyncQueue[BeaconBlockHeader]()
      # Test data is retrieved from mainnet
      metadata = loadMainnetData()
      genesisState =
        try:
          template genesisData(): auto = metadata.genesisData
          newClone(readSszForkedHashedBeaconState(
            metadata.cfg, genesisData.toOpenArrayByte(genesisData.low, genesisData.high)))
        except CatchableError as err:
          raiseAssert "Invalid baked-in state: " & err.msg

      beaconClock = BeaconClock.init(getStateField(genesisState[], genesis_time))

      # TODO: Should probably mock somehow passing time.
      getBeaconTime = beaconClock.getBeaconTimeFn()

      genesis_validators_root =
        getStateField(genesisState[], genesis_validators_root)

      forkDigests = newClone ForkDigests.init(metadata.cfg, genesis_validators_root)

      lcNode1 = newLCNode(rng, 20302, forkDigests[])
      lcNode2 = newLCNode(rng, 20303, forkDigests[])
      bootstrap = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      bootstrapHeaderHash = hash_tree_root(bootstrap.header)

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
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
      encodeBootstrapForked(forkDigests.altair, bootstrap)
    )

    let lc = LightClient.new(
      lcNode1.lightClientNetwork,
      rng,
      metadata.cfg,
      forkDigests,
      getBeaconTime,
      genesis_validators_root,
      LightClientFinalizationMode.Optimistic
    )

    lc.onFinalizedHeader = headerCallback(finalHeaders)
    lc.onOptimisticHeader = headerCallback(optimisticHeaders)
    lc.trustedBlockRoot = some bootstrapHeaderHash

    # After start light client will try to retrieve bootstrap for given
    # trustedBlockRoot
    lc.start()

    # wait till light client retrieves bootstrap. Upon receving bootstrap
    # both callbacks should be called onFinalizedHeader and onOptimisticHeader
    let
      receivedFinalHeader = await finalHeaders.get()
      receivedOptimisticHeader = await optimisticHeaders.get()

    check:
      hash_tree_root(receivedFinalHeader) == bootstrapHeaderHash
      hash_tree_root(receivedOptimisticHeader) == bootstrapHeaderHash


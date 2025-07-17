# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  eth/p2p/discoveryv5/protocol,
  beacon_chain/spec/forks,
  stew/byteutils,
  ../eth_data/history_data_ssz_e2s,
  ../database/content_db,
  ./network_metadata,
  ./wire/[portal_stream, portal_protocol_config],
  ./beacon/[beacon_init_loader, beacon_light_client],
  ./legacy_history/[history_network, history_content]

from eth/p2p/discoveryv5/routing_table import logDistance

export
  beacon_light_client, history_network, portal_protocol_config, forks

type
  PortalNodeConfig* = object
    accumulatorFile*: Opt[string]
    trustedBlockRoot*: Opt[Digest]
    portalConfig*: PortalProtocolConfig
    dataDir*: string
    storageCapacity*: uint64
    contentRequestRetries*: int
    contentQueueWorkers*: int
    contentQueueSize*: int

  PortalNode* = ref object
    discovery: protocol.Protocol
    contentDB: ContentDB
    streamManager: StreamManager
    beaconNetwork*: Opt[BeaconNetwork]
    legacyHistoryNetwork*: Opt[LegacyHistoryNetwork]
    beaconLightClient*: Opt[LightClient]
    statusLogLoop: Future[void]

# Beacon light client application callbacks triggered when new finalized header
# or optimistic header is available.
proc onFinalizedHeader(
    lightClient: LightClient, finalizedHeader: ForkedLightClientHeader
) =
  withForkyHeader(finalizedHeader):
    when lcDataFork > LightClientDataFork.None:
      info "New LC finalized header", finalized_header = shortLog(forkyHeader)

proc onOptimisticHeader(
    lightClient: LightClient, optimisticHeader: ForkedLightClientHeader
) =
  withForkyHeader(optimisticHeader):
    when lcDataFork > LightClientDataFork.None:
      info "New LC optimistic header", optimistic_header = shortLog(forkyHeader)

proc getDbDirectory*(network: PortalNetwork): string =
  if network == PortalNetwork.mainnet:
    "db"
  else:
    "db_" & network.symbolName()

proc new*(
    T: type PortalNode,
    network: PortalNetwork,
    config: PortalNodeConfig,
    discovery: protocol.Protocol,
    subnetworks: set[PortalSubnetwork],
    bootstrapRecords: openArray[Record] = [],
    rng = newRng(),
): T =
  let
    # Store the database at contentdb prefixed with the first 8 chars of node id.
    # This is done because the content in the db is dependant on the `NodeId` and
    # the selected `Radius`.
    contentDB = ContentDB.new(
      config.dataDir / network.getDbDirectory() / "contentdb_" &
        discovery.localNode.id.toBytesBE().toOpenArray(0, 8).toHex(),
      storageCapacity = config.storageCapacity,
      radiusConfig = config.portalConfig.radiusConfig,
      localId = discovery.localNode.id,
    )
    # TODO: Portal works only over mainnet data currently
    networkData = loadNetworkData("mainnet")
    streamManager = StreamManager.new(discovery)
    accumulator =
      # Building an accumulator from header epoch files takes > 2m30s and is
      # thus not really a viable option at start-up.
      # Options are:
      # - Start with baked-in accumulator
      # - Start with file containing SSZ encoded accumulator
      if config.accumulatorFile.isSome:
        readAccumulator(config.accumulatorFile.value).expect(
          "Need a file with a valid SSZ encoded accumulator"
        )
      else:
        # Get it from binary file containing SSZ encoded accumulator
        loadAccumulator()

    beaconNetwork =
      if PortalSubnetwork.beacon in subnetworks:
        let
          beaconDb = BeaconDb.new(networkData, config.dataDir / "db" / "beacon_db")
          beaconNetwork = BeaconNetwork.new(
            network,
            discovery,
            beaconDb,
            streamManager,
            networkData.forks,
            networkData.clock.getBeaconTimeFn(),
            networkData.metadata.cfg,
            config.trustedBlockRoot,
            bootstrapRecords = bootstrapRecords,
            portalConfig = config.portalConfig,
            contentQueueWorkers = config.contentQueueWorkers,
            contentQueueSize = config.contentQueueSize,
          )
        Opt.some(beaconNetwork)
      else:
        Opt.none(BeaconNetwork)

    legacyHistoryNetwork =
      if PortalSubnetwork.legacyHistory in subnetworks:
        Opt.some(
          LegacyHistoryNetwork.new(
            network,
            discovery,
            contentDB,
            streamManager,
            networkData.metadata.cfg,
            accumulator,
            beaconDbCache =
              if beaconNetwork.isSome():
                beaconNetwork.value().beaconDb.beaconDbCache
              else:
                BeaconDbCache(),
            bootstrapRecords = bootstrapRecords,
            portalConfig = config.portalConfig,
            contentRequestRetries = config.contentRequestRetries,
            contentQueueWorkers = config.contentQueueWorkers,
            contentQueueSize = config.contentQueueSize,
          )
        )
      else:
        Opt.none(LegacyHistoryNetwork)

    beaconLightClient =
      if beaconNetwork.isSome():
        let beaconLightClient = LightClient.new(
          beaconNetwork.value, rng, networkData, LightClientFinalizationMode.Optimistic
        )

        beaconLightClient.onFinalizedHeader = onFinalizedHeader
        beaconLightClient.onOptimisticHeader = onOptimisticHeader

        # TODO:
        # Quite dirty. Use register validate callbacks instead. Or, revisit
        # the object relationships regarding the beacon light client.
        beaconNetwork.value.processor = beaconLightClient.processor

        Opt.some(beaconLightClient)
      else:
        Opt.none(LightClient)

  PortalNode(
    discovery: discovery,
    contentDB: contentDB,
    streamManager: streamManager,
    beaconNetwork: beaconNetwork,
    legacyHistoryNetwork: legacyHistoryNetwork,
    beaconLightClient: beaconLightClient,
  )

proc statusLogLoop(n: PortalNode) {.async: (raises: []).} =
  try:
    while true:
      # This is the data radius percentage compared to full storage. This will
      # drop a lot when using the logbase2 scale, namely `/ 2` per 1 logaritmic
      # radius drop.
      # TODO: Get some float precision calculus?
      let
        radius = n.contentDB.dataRadius
        radiusPercentage = radius div (UInt256.high() div u256(100))
        logRadius = logDistance(radius, u256(0))

      info "Portal node status",
        dbSize = $(n.contentDB.size() div 1_000_000) & "mb",
        radiusPercentage = radiusPercentage.toString(10) & "%",
        radius = radius.toHex(),
        logRadius

      await sleepAsync(60.seconds)
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: PortalNode) =
  debug "Starting Portal node"

  n.discovery.start()

  if n.beaconNetwork.isSome():
    n.beaconNetwork.value.start()
  if n.legacyHistoryNetwork.isSome():
    n.legacyHistoryNetwork.value.start()
  if n.beaconLightClient.isSome():
    n.beaconLightClient.value.start()

  n.statusLogLoop = statusLogLoop(n)

proc stop*(n: PortalNode) {.async: (raises: []).} =
  debug "Stopping Portal node"

  var futures: seq[Future[void]]

  if n.beaconNetwork.isSome():
    futures.add(n.beaconNetwork.value.stop())
  if n.legacyHistoryNetwork.isSome():
    futures.add(n.legacyHistoryNetwork.value.stop())
  if n.beaconLightClient.isSome():
    futures.add(n.beaconLightClient.value.stop())
  if not n.statusLogLoop.isNil():
    futures.add(n.statusLogLoop.cancelAndWait())

  await noCancel(allFutures(futures))

  await n.discovery.closeWait()
  n.contentDB.close()
  n.statusLogLoop = nil

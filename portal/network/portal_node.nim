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
  ../eth_history/history_data_ssz_e2s,
  ../database/content_db,
  ./wire/[portal_stream, portal_protocol_config],
  ./history/history_network,
  ./beacon/[beacon_init_loader, beacon_light_client]

from eth/p2p/discoveryv5/routing_table import logDistance

export beacon_light_client, history_network, portal_protocol_config, forks

type
  PortalNodeConfig* = object
    trustedBlockRoot*: Opt[Digest]
    portalConfig*: PortalProtocolConfig
    dataDir*: string
    storageCapacity*: uint64
    contentRequestRetries*: int
    contentQueueWorkers*: int
    contentQueueSize*: int

  PortalNode* = ref object
    discovery: protocol.Protocol
    streamManager: StreamManager
    historyNetwork*: Opt[HistoryNetwork]
    beaconNetwork*: Opt[BeaconNetwork]
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

const dbDir* = "portaldb"

proc new*(
    T: type PortalNode,
    network: PortalNetwork,
    config: PortalNodeConfig,
    discovery: protocol.Protocol,
    subnetworks: set[PortalSubnetwork],
    headerCallback: GetHeaderCallback = defaultNoGetHeader,
    bootstrapRecords: openArray[Record] = [],
    rng = newRng(),
): T =
  let
    networkData =
      case network
      of PortalNetwork.mainnet:
        loadNetworkData("mainnet")
      of PortalNetwork.none:
        loadNetworkData("mainnet")

    streamManager = StreamManager.new(discovery)

    historyNetwork =
      if PortalSubnetwork.history in subnetworks:
        # Store the database at contentdb prefixed with the first 8 chars of node id.
        # This is done because the content in the db is dependant on the `NodeId` and
        # the selected `Radius`.
        let contentDB = ContentDB.new(
          config.dataDir / dbDir,
          storageCapacity = config.storageCapacity,
          radiusConfig = config.portalConfig.radiusConfig,
          localId = discovery.localNode.id,
          subnetwork = PortalSubnetwork.history,
        )
        Opt.some(
          HistoryNetwork.new(
            network,
            discovery,
            contentDB,
            streamManager,
            headerCallback,
            bootstrapRecords = bootstrapRecords,
            portalConfig = config.portalConfig,
            contentRequestRetries = config.contentRequestRetries,
            contentQueueWorkers = config.contentQueueWorkers,
            contentQueueSize = config.contentQueueSize,
          )
        )
      else:
        Opt.none(HistoryNetwork)

    beaconNetwork =
      if PortalSubnetwork.beacon in subnetworks:
        let
          beaconDb = BeaconDb.new(networkData, config.dataDir / dbDir)
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
    streamManager: streamManager,
    historyNetwork: historyNetwork,
    beaconNetwork: beaconNetwork,
    beaconLightClient: beaconLightClient,
  )

proc statusLogLoop(n: PortalNode) {.async: (raises: []).} =
  try:
    while true:
      # This is the data radius percentage compared to full storage. This will
      # drop a lot when using the logbase2 scale, namely `/ 2` per 1 logaritmic
      # radius drop.
      # TODO: Get some float precision calculus?
      if n.historyNetwork.isSome():
        let
          radius = n.historyNetwork.value.contentDB.dataRadius
          radiusPercentage = radius div (UInt256.high() div u256(100))
          logRadius = logDistance(radius, u256(0))

        info "Portal node status",
          radiusPercentage = radiusPercentage.toString(10) & "%",
          radius = radius.toHex(),
          logRadius

      await sleepAsync(60.seconds)
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: PortalNode) =
  debug "Starting Portal node"

  n.discovery.start()

  if n.historyNetwork.isSome():
    n.historyNetwork.value.start()
  if n.beaconNetwork.isSome():
    n.beaconNetwork.value.start()
  if n.beaconLightClient.isSome():
    n.beaconLightClient.value.start()

  n.statusLogLoop = statusLogLoop(n)

proc stop*(n: PortalNode) {.async: (raises: []).} =
  debug "Stopping Portal node"

  var futures: seq[Future[void]]

  if not n.statusLogLoop.isNil():
    futures.add(n.statusLogLoop.cancelAndWait())
  if n.historyNetwork.isSome():
    futures.add(n.historyNetwork.value.stop())
  if n.beaconNetwork.isSome():
    futures.add(n.beaconNetwork.value.stop())
  if n.beaconLightClient.isSome():
    futures.add(n.beaconLightClient.value.stop())

  await noCancel(allFutures(futures))

  await n.discovery.closeWait()
  n.statusLogLoop = nil

# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  eth/p2p/discoveryv5/protocol,
  beacon_chain/spec/forks,
  ./network_metadata,
  ./eth_data/history_data_ssz_e2s,
  ./database/content_db,
  ./network/wire/[portal_stream, portal_protocol_config],
  ./network/beacon/[beacon_init_loader, beacon_light_client],
  ./network/history/[history_network, history_content],
  ./network/state/[state_network, state_content]

export
  beacon_light_client, history_network, state_network, portal_protocol_config, forks

type
  PortalNodeConfig* = object
    accumulatorFile*: Opt[string]
    disableStateRootValidation*: bool
    trustedBlockRoot*: Opt[Digest]
    portalConfig*: PortalProtocolConfig
    dataDir*: string
    storageCapacity*: uint64

  PortalNode* = ref object
    discovery: protocol.Protocol
    contentDB: ContentDB
    streamManager: StreamManager
    beaconNetwork*: Opt[BeaconNetwork]
    historyNetwork*: Opt[HistoryNetwork]
    stateNetwork*: Opt[StateNetwork]
    beaconLightClient*: Opt[LightClient]

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
      if PortalSubnetwork.beacon in subnetworks and config.trustedBlockRoot.isSome():
        let
          beaconDb = BeaconDb.new(networkData, config.dataDir / "db" / "beacon_db")
          beaconNetwork = BeaconNetwork.new(
            network,
            discovery,
            beaconDb,
            streamManager,
            networkData.forks,
            bootstrapRecords = bootstrapRecords,
            portalConfig = config.portalConfig,
          )
        Opt.some(beaconNetwork)
      else:
        Opt.none(BeaconNetwork)

    historyNetwork =
      if PortalSubnetwork.history in subnetworks:
        Opt.some(
          HistoryNetwork.new(
            network,
            discovery,
            contentDB,
            streamManager,
            accumulator,
            bootstrapRecords = bootstrapRecords,
            portalConfig = config.portalConfig,
          )
        )
      else:
        Opt.none(HistoryNetwork)

    stateNetwork =
      if PortalSubnetwork.state in subnetworks:
        Opt.some(
          StateNetwork.new(
            network,
            discovery,
            contentDB,
            streamManager,
            bootstrapRecords = bootstrapRecords,
            portalConfig = config.portalConfig,
            historyNetwork = historyNetwork,
            not config.disableStateRootValidation,
          )
        )
      else:
        Opt.none(StateNetwork)

    beaconLightClient =
      if beaconNetwork.isSome():
        let beaconLightClient = LightClient.new(
          beaconNetwork.value, rng, networkData, LightClientFinalizationMode.Optimistic
        )

        beaconLightClient.onFinalizedHeader = onFinalizedHeader
        beaconLightClient.onOptimisticHeader = onOptimisticHeader
        beaconLightClient.trustedBlockRoot = config.trustedBlockRoot

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
    historyNetwork: historyNetwork,
    stateNetwork: stateNetwork,
    beaconLightClient: beaconLightClient,
  )

proc start*(n: PortalNode) =
  if n.beaconNetwork.isSome():
    n.beaconNetwork.value.start()
  if n.historyNetwork.isSome():
    n.historyNetwork.value.start()
  if n.stateNetwork.isSome():
    n.stateNetwork.value.start()

    if n.beaconLightClient.isSome():
      n.beaconLightClient.value.start()

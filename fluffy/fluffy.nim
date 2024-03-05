# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  confutils,
  confutils/std/net,
  chronicles,
  chronicles/topics_registry,
  chronos,
  metrics,
  metrics/chronos_httpserver,
  json_rpc/clients/httpclient,
  json_rpc/rpcproxy,
  stew/[byteutils, io2, results],
  eth/keys,
  eth/net/nat,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/beacon_clock,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  beacon_chain/gossip_processing/light_client_processor,
  ./conf,
  ./network_metadata,
  ./common/common_utils,
  ./rpc/
    [rpc_web3_api, rpc_eth_api, rpc_discovery_api, rpc_portal_api, rpc_portal_debug_api],
  ./network/state/[state_network, state_content],
  ./network/history/[history_network, history_content],
  ./network/beacon/[beacon_init_loader, beacon_light_client],
  ./network/wire/[portal_stream, portal_protocol_config],
  ./eth_data/history_data_ssz_e2s,
  ./database/content_db,
  ./version,
  ./logging

chronicles.formatIt(IoErrorCode):
  $it

# Application callbacks used when new finalized header or optimistic header is
# available.
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

proc run(config: PortalConf) {.raises: [CatchableError].} =
  setupLogging(config.logLevel, config.logStdout)

  notice "Launching Fluffy", version = fullVersionStr, cmdParams = commandLineParams()

  # Make sure dataDir exists
  let pathExists = createPath(config.dataDir.string)
  if pathExists.isErr():
    fatal "Failed to create data directory",
      dataDir = config.dataDir, error = pathExists.error
    quit 1

  let
    rng = newRng()
    bindIp = config.listenAddress
    udpPort = Port(config.udpPort)
    # TODO: allow for no TCP port mapping!
    (extIp, _, extUdpPort) =
      try:
        setupAddress(config.nat, config.listenAddress, udpPort, udpPort, "fluffy")
      except CatchableError as exc:
        raise exc # TODO: Ideally we don't have the Exception here
      except Exception as exc:
        raiseAssert exc.msg
    (netkey, newNetKey) =
      if config.networkKey.isSome():
        (config.networkKey.get(), true)
      else:
        getPersistentNetKey(rng[], config.networkKeyFile)

    enrFilePath = config.dataDir / "fluffy_node.enr"
    previousEnr =
      if not newNetKey:
        getPersistentEnr(enrFilePath)
      else:
        Opt.none(enr.Record)

  var bootstrapRecords: seq[Record]
  loadBootstrapFile(string config.bootstrapNodesFile, bootstrapRecords)
  bootstrapRecords.add(config.bootstrapNodes)

  var portalNetwork: PortalNetwork
  if config.portalNetworkDeprecated.isSome():
    warn "DEPRECATED: The --network flag will be removed in the future, please use the drop in replacement --portal-network flag instead"
    portalNetwork = config.portalNetworkDeprecated.get()
  else:
    portalNetwork = config.portalNetwork

  case portalNetwork
  of testnet0:
    for enrURI in testnet0BootstrapNodes:
      var record: Record
      if fromURI(record, enrURI):
        bootstrapRecords.add(record)
  else:
    discard

  let
    discoveryConfig =
      DiscoveryConfig.init(config.tableIpLimit, config.bucketIpLimit, config.bitsPerHop)
    d = newProtocol(
      netkey,
      extIp,
      none(Port),
      extUdpPort,
      # Note: The addition of default clientInfo to the ENR is a temporary
      # measure to easily identify & debug the clients used in the testnet.
      # Might make this into a, default off, cli option.
      localEnrFields = {"c": enrClientInfoShort},
      bootstrapRecords = bootstrapRecords,
      previousRecord =
        # TODO: discv5/enr code still uses Option, to be changed.
        if previousEnr.isSome():
          some(previousEnr.get())
        else:
          none(enr.Record)
      ,
      bindIp = bindIp,
      bindPort = udpPort,
      enrAutoUpdate = config.enrAutoUpdate,
      config = discoveryConfig,
      rng = rng,
    )

  d.open()

  # Force pruning
  if config.forcePrune:
    let db = ContentDB.new(
      config.dataDir / "db" / "contentdb_" &
        d.localNode.id.toBytesBE().toOpenArray(0, 8).toHex(),
      storageCapacity = config.storageCapacityMB * 1_000_000,
      manualCheckpoint = true,
    )

    let radius =
      if config.radiusConfig.kind == Static:
        UInt256.fromLogRadius(config.radiusConfig.logRadius)
      else:
        let oldRadiusApproximation = db.getLargestDistance(d.localNode.id)
        db.estimateNewRadius(oldRadiusApproximation)

    # Note: In the case of dynamical radius this is all an approximation that
    # heavily relies on uniformly distributed content and thus will always
    # have an error margin, either down or up of the requested capacity.
    # TODO I: Perhaps we want to add an offset to counter the latter.
    # TODO II: Perhaps for dynamical radius, we want to also apply the vacuum
    # without the forcePrune flag and purely by checking the amount of free
    # space versus the pruning fraction.
    # TODO III: Adding Radius metadata to the db could be yet another way to
    # decide whether or not to force prune, instead of this flag.
    db.forcePrune(d.localNode.id, radius)
    db.close()

  # Store the database at contentdb prefixed with the first 8 chars of node id.
  # This is done because the content in the db is dependant on the `NodeId` and
  # the selected `Radius`.
  let
    db = ContentDB.new(
      config.dataDir / "db" / "contentdb_" &
        d.localNode.id.toBytesBE().toOpenArray(0, 8).toHex(),
      storageCapacity = config.storageCapacityMB * 1_000_000,
    )

    portalConfig = PortalProtocolConfig.init(
      config.tableIpLimit, config.bucketIpLimit, config.bitsPerHop, config.radiusConfig,
      config.disablePoke,
    )
    streamManager = StreamManager.new(d)

    stateNetwork =
      if Network.state in config.networks:
        Opt.some(
          StateNetwork.new(
            d,
            db,
            streamManager,
            bootstrapRecords = bootstrapRecords,
            portalConfig = portalConfig,
          )
        )
      else:
        Opt.none(StateNetwork)

    accumulator =
      # Building an accumulator from header epoch files takes > 2m30s and is
      # thus not really a viable option at start-up.
      # Options are:
      # - Start with baked-in accumulator
      # - Start with file containing SSZ encoded accumulator
      if config.accumulatorFile.isSome():
        readAccumulator(string config.accumulatorFile.get()).expect(
          "Need a file with a valid SSZ encoded accumulator"
        )
      else:
        # Get it from binary file containing SSZ encoded accumulator
        try:
          SSZ.decode(finishedAccumulator, FinishedAccumulator)
        except SszError as err:
          raiseAssert "Invalid baked-in accumulator: " & err.msg

    historyNetwork =
      if Network.history in config.networks:
        Opt.some(
          HistoryNetwork.new(
            d,
            db,
            streamManager,
            accumulator,
            bootstrapRecords = bootstrapRecords,
            portalConfig = portalConfig,
          )
        )
      else:
        Opt.none(HistoryNetwork)

    beaconLightClient =
      # TODO: Currently disabled by default as it is not sufficiently polished.
      # Eventually this should be always-on functionality.
      if Network.beacon in config.networks and config.trustedBlockRoot.isSome():
        let
          # Portal works only over mainnet data currently
          networkData = loadNetworkData("mainnet")
          beaconDb = BeaconDb.new(networkData, config.dataDir / "db" / "beacon_db")
          beaconNetwork = BeaconNetwork.new(
            d,
            beaconDb,
            streamManager,
            networkData.forks,
            bootstrapRecords = bootstrapRecords,
            portalConfig = portalConfig,
          )

        let beaconLightClient = LightClient.new(
          beaconNetwork, rng, networkData, LightClientFinalizationMode.Optimistic
        )

        beaconLightClient.onFinalizedHeader = onFinalizedHeader
        beaconLightClient.onOptimisticHeader = onOptimisticHeader
        beaconLightClient.trustedBlockRoot = config.trustedBlockRoot

        # TODO:
        # Quite dirty. Use register validate callbacks instead. Or, revisit
        # the object relationships regarding the beacon light client.
        beaconNetwork.processor = beaconLightClient.processor

        Opt.some(beaconLightClient)
      else:
        Opt.none(LightClient)

  # TODO: If no new network key is generated then we should first check if an
  # enr file exists, and in the case it does read out the seqNum from it and
  # reuse that.
  let enrFile = config.dataDir / "fluffy_node.enr"
  if io2.writeFile(enrFile, d.localNode.record.toURI()).isErr:
    fatal "Failed to write the enr file", file = enrFile
    quit 1

  ## Start metrics HTTP server
  if config.metricsEnabled:
    let
      address = config.metricsAddress
      port = config.metricsPort
    info "Starting metrics HTTP server",
      url = "http://" & $address & ":" & $port & "/metrics"
    try:
      chronos_httpserver.startMetricsHttpServer($address, port)
    except CatchableError as exc:
      raise exc
    # TODO: Ideally we don't have the Exception here
    except Exception as exc:
      raiseAssert exc.msg

  ## Starting the different networks.
  d.start()
  if stateNetwork.isSome():
    stateNetwork.get().start()
  if historyNetwork.isSome():
    historyNetwork.get().start()
  if beaconLightClient.isSome():
    let lc = beaconLightClient.get()
    lc.network.start()
    lc.start()

    proc onSecond(time: Moment) =
      discard
      # TODO:
      # Figure out what to do with this one.
      # let wallSlot = lc.getBeaconTime().slotOrZero()
      # lc.updateGossipStatus(wallSlot + 1)

    proc runOnSecondLoop() {.async.} =
      let sleepTime = chronos.seconds(1)
      while true:
        let start = chronos.now(chronos.Moment)
        await chronos.sleepAsync(sleepTime)
        let afterSleep = chronos.now(chronos.Moment)
        let sleepTime = afterSleep - start
        onSecond(start)
        let finished = chronos.now(chronos.Moment)
        let processingTime = finished - afterSleep
        trace "onSecond task completed", sleepTime, processingTime

    onSecond(Moment.now())

    asyncSpawn runOnSecondLoop()

  ## Starting the JSON-RPC APIs
  if config.rpcEnabled:
    let ta = initTAddress(config.rpcAddress, config.rpcPort)
    var rpcHttpServerWithProxy = RpcProxy.new([ta], config.proxyUri)
    rpcHttpServerWithProxy.installDiscoveryApiHandlers(d)
    rpcHttpServerWithProxy.installWeb3ApiHandlers()
    if stateNetwork.isSome():
      rpcHttpServerWithProxy.installPortalApiHandlers(
        stateNetwork.get().portalProtocol, "state"
      )
    if historyNetwork.isSome():
      rpcHttpServerWithProxy.installEthApiHandlers(
        historyNetwork.get(), beaconLightClient
      )
      rpcHttpServerWithProxy.installPortalApiHandlers(
        historyNetwork.get().portalProtocol, "history"
      )
      rpcHttpServerWithProxy.installPortalDebugApiHandlers(
        historyNetwork.get().portalProtocol, "history"
      )
    if beaconLightClient.isSome():
      rpcHttpServerWithProxy.installPortalApiHandlers(
        beaconLightClient.get().network.portalProtocol, "beacon"
      )
    # TODO: Test proxy with remote node over HTTPS
    waitFor rpcHttpServerWithProxy.start()

  runForever()

when isMainModule:
  {.pop.}
  let config = PortalConf.load(
    version = clientName & " " & fullVersionStr & "\p\p" & nimBanner,
    copyrightBanner = copyrightBanner,
  )
  {.push raises: [].}

  case config.cmd
  of PortalCmd.noCommand:
    run(config)

# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/os,
  confutils, confutils/std/net, chronicles, chronicles/topics_registry,
  chronos, metrics, metrics/chronos_httpserver, json_rpc/clients/httpclient,
  json_rpc/rpcproxy, stew/[byteutils, io2],
  eth/keys, eth/net/nat,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  beacon_chain/beacon_clock,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  beacon_chain/gossip_processing/light_client_processor,
  ./conf, ./network_metadata, ./common/common_utils,
  ./rpc/[rpc_eth_api, bridge_client, rpc_discovery_api, rpc_portal_api,
    rpc_portal_debug_api],
  ./network/state/[state_network, state_content],
  ./network/history/[history_network, history_content],
  ./network/beacon_light_client/[
    light_client_init_loader,
    light_client_content,
    beacon_light_client,
    light_client_db,
    light_client_network
  ],
  ./network/wire/[portal_stream, portal_protocol_config],
  ./data/[history_data_seeding, history_data_parser],
  ./content_db

proc initializeBridgeClient(maybeUri: Option[string]): Option[BridgeClient] =
  try:
    if (maybeUri.isSome()):
      let uri = maybeUri.unsafeGet()
      # TODO: Add possiblity to start client on differnt transports based on uri.
      let httpClient = newRpcHttpClient()
      waitFor httpClient.connect(uri)
      notice "Initialized bridge client:", uri = uri
      return some[BridgeClient](httpClient)
    else:
      return none(BridgeClient)
  except CatchableError as err:
    notice "Failed to initialize bridge client", error = err.msg
    return none(BridgeClient)

proc run(config: PortalConf) {.raises: [CatchableError, Defect].} =
  # Make sure dataDir exists
  let pathExists = createPath(config.dataDir.string)
  if pathExists.isErr():
    fatal "Failed to create data directory", dataDir = config.dataDir,
      error = pathExists.error
    quit 1

  let
    rng = newRng()
    bindIp = config.listenAddress
    udpPort = Port(config.udpPort)
    # TODO: allow for no TCP port mapping!
    (extIp, _, extUdpPort) =
      try: setupAddress(config.nat,
        config.listenAddress, udpPort, udpPort, "dcli")
      except CatchableError as exc: raise exc
      # TODO: Ideally we don't have the Exception here
      except Exception as exc: raiseAssert exc.msg
    netkey =
      if config.networkKey.isSome():
        config.networkKey.get()
      else:
        getPersistentNetKey(rng[], config.networkKeyFile, config.dataDir.string)

  var bootstrapRecords: seq[Record]
  loadBootstrapFile(string config.bootstrapNodesFile, bootstrapRecords)
  bootstrapRecords.add(config.bootstrapNodes)

  case config.portalNetwork
  of testnet0:
    for enrURI in testnet0BootstrapNodes:
      var record: Record
      if fromURI(record, enrURI):
        bootstrapRecords.add(record)
  else:
    discard

  let
    discoveryConfig = DiscoveryConfig.init(
      config.tableIpLimit, config.bucketIpLimit, config.bitsPerHop)
    d = newProtocol(
      netkey,
      extIp, none(Port), extUdpPort,
      bootstrapRecords = bootstrapRecords,
      bindIp = bindIp, bindPort = udpPort,
      enrAutoUpdate = config.enrAutoUpdate,
      config = discoveryConfig,
      rng = rng)

  d.open()

  # Store the database at contentdb prefixed with the first 8 chars of node id.
  # This is done because the content in the db is dependant on the `NodeId` and
  # the selected `Radius`.
  let
    db = ContentDB.new(config.dataDir / "db" / "contentdb_" &
      d.localNode.id.toByteArrayBE().toOpenArray(0, 8).toHex(), maxSize = config.storageSize)

    portalConfig = PortalProtocolConfig.init(
      config.tableIpLimit,
      config.bucketIpLimit,
      config.bitsPerHop,
      config.radiusConfig
    )
    streamManager = StreamManager.new(d)

    stateNetwork = StateNetwork.new(d, db, streamManager,
      bootstrapRecords = bootstrapRecords, portalConfig = portalConfig)

    accumulator =
      # Building an accumulator from header epoch files takes > 2m30s and is
      # thus not really a viable option at start-up.
      # Options are:
      # - Start with baked-in accumulator
      # - Start with file containing SSZ encoded accumulator
      if config.accumulatorFile.isSome():
        readAccumulator(string config.accumulatorFile.get()).expect(
          "Need a file with a valid SSZ encoded accumulator")
      else:
        # Get it from binary file containing SSZ encoded accumulator
        try:
          SSZ.decode(finishedAccumulator, FinishedAccumulator)
        except SszError as err:
          raiseAssert "Invalid baked-in accumulator: " & err.msg

    historyNetwork = HistoryNetwork.new(d, db, streamManager, accumulator,
      bootstrapRecords = bootstrapRecords, portalConfig = portalConfig)

  # TODO: If no new network key is generated then we should first check if an
  # enr file exists, and in the case it does read out the seqNum from it and
  # reuse that.
  let enrFile = config.dataDir / "fluffy_node.enr"
  if io2.writeFile(enrFile, d.localNode.record.toURI()).isErr:
    fatal "Failed to write the enr file", file = enrFile
    quit 1

  if config.metricsEnabled:
    let
      address = config.metricsAddress
      port = config.metricsPort
    info "Starting metrics HTTP server",
      url = "http://" & $address & ":" & $port & "/metrics"
    try:
      chronos_httpserver.startMetricsHttpServer($address, port)
    except CatchableError as exc: raise exc
    # TODO: Ideally we don't have the Exception here
    except Exception as exc: raiseAssert exc.msg

  if config.rpcEnabled:
    let ta = initTAddress(config.rpcAddress, config.rpcPort)
    var rpcHttpServerWithProxy = RpcProxy.new([ta], config.proxyUri)
    rpcHttpServerWithProxy.installEthApiHandlers(historyNetwork)
    rpcHttpServerWithProxy.installDiscoveryApiHandlers(d)
    rpcHttpServerWithProxy.installPortalApiHandlers(stateNetwork.portalProtocol, "state")
    rpcHttpServerWithProxy.installPortalApiHandlers(historyNetwork.portalProtocol, "history")
    rpcHttpServerWithProxy.installPortalDebugApiHandlers(stateNetwork.portalProtocol, "state")
    rpcHttpServerWithProxy.installPortalDebugApiHandlers(historyNetwork.portalProtocol, "history")
    # TODO for now we can only proxy to local node (or remote one without ssl) to make it possible
    # to call infura https://github.com/status-im/nim-json-rpc/pull/101 needs to get merged for http client to support https/
    waitFor rpcHttpServerWithProxy.start()

  let bridgeClient = initializeBridgeClient(config.bridgeUri)

  d.start()

  # TODO: Currently disabled by default as it is not stable/polished enough,
  # ultimatetely this should probably be always on.
  if config.trustedBlockRoot.isSome():
    # fluffy light client works only over mainnet data
    let
      networkData = loadNetworkData("mainnet")

      db = LightClientDb.new(config.dataDir / "lightClientDb")

      lightClientNetwork = LightClientNetwork.new(
        d,
        db,
        streamManager,
        networkData.forks,
        bootstrapRecords = bootstrapRecords)

      getBeaconTime = networkData.clock.getBeaconTimeFn()

      refDigests = newClone networkData.forks

      lc = LightClient.new(
        lightClientNetwork,
        rng,
        networkData.metadata.cfg,
        refDigests,
        getBeaconTime,
        networkData.genesis_validators_root,
        LightClientFinalizationMode.Optimistic
      )

    # TODO: For now just log headers. Ultimately we should also use callbacks for each
    # lc object to save them to db and offer them to the network.
    proc onFinalizedHeader(
        lightClient: LightClient, finalizedHeader: BeaconBlockHeader) =
      info "New LC finalized header",
        finalized_header = shortLog(finalizedHeader)

    proc onOptimisticHeader(
        lightClient: LightClient, optimisticHeader: BeaconBlockHeader) =
      info "New LC optimistic header",
        optimistic_header = shortLog(optimisticHeader)

    lc.onFinalizedHeader = onFinalizedHeader
    lc.onOptimisticHeader = onOptimisticHeader
    lc.trustedBlockRoot = config.trustedBlockRoot

    proc onSecond(time: Moment) =
      let wallSlot = getBeaconTime().slotOrZero()
      # TODO this is a place to enable/disable gossip based on the current status
      # of light client
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

    lightClientNetwork.start()
    lc.start()

    asyncSpawn runOnSecondLoop()

  historyNetwork.start()
  stateNetwork.start()

  runForever()

when isMainModule:
  {.pop.}
  let config = PortalConf.load()
  {.push raises: [Defect].}

  setLogLevel(config.logLevel)

  case config.cmd
  of PortalCmd.noCommand:
    run(config)

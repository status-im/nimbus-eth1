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
  ./conf, ./network_metadata, ./common/common_utils,
  ./rpc/[rpc_eth_api, bridge_client, rpc_discovery_api, rpc_portal_api,
    rpc_portal_debug_api],
  ./network/state/[state_network, state_content],
  ./network/history/[history_network, history_content],
  ./network/wire/[portal_stream, portal_protocol_config],
  "."/[content_db, populate_db]

proc fromLogRadius(T: type UInt256, logRadius: uint16): T =
  # Get the max value of the logRadius range
  pow((2).stuint(256), logRadius) - 1
  # For the min value do `pow((2).stuint(256), logRadius - 1)`

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
    radius = UInt256.fromLogRadius(config.logRadius)
    db = ContentDB.new(config.dataDir / "db" / "contentdb_" &
      d.localNode.id.toByteArrayBE().toOpenArray(0, 8).toHex())

    portalConfig = PortalProtocolConfig.init(
      config.tableIpLimit, config.bucketIpLimit, config.bitsPerHop)
    stateNetwork = StateNetwork.new(d, db, radius,
      bootstrapRecords = bootstrapRecords, portalConfig = portalConfig)
    historyNetwork = HistoryNetwork.new(d, db, radius,
      bootstrapRecords = bootstrapRecords, portalConfig = portalConfig)

  # One instance of UtpDiscv5Protocol is shared over all the PortalStreams.
  let
    maxPayloadSize = uint32(discv5MaxSize - talkReqOverhead - utpHeaderOverhead)
    socketConfig = SocketConfig.init(
      incomingSocketReceiveTimeout = none(Duration), payloadSize = maxPayloadSize)
    streamTransport = UtpDiscv5Protocol.new(
      d,
      utpProtocolId,
      registerIncomingSocketCallback(@[
        stateNetwork.portalProtocol.stream,
        historyNetwork.portalProtocol.stream]),
      allowRegisteredIdCallback(@[
        stateNetwork.portalProtocol.stream,
        historyNetwork.portalProtocol.stream]),
      socketConfig)
  stateNetwork.setStreamTransport(streamTransport)
  historyNetwork.setStreamTransport(streamTransport)

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
  stateNetwork.start()
  historyNetwork.start()

  runForever()

when isMainModule:
  {.pop.}
  let config = PortalConf.load()
  {.push raises: [Defect].}

  setLogLevel(config.logLevel)

  case config.cmd
  of PortalCmd.noCommand:
    run(config)
  of PortalCmd.populateHistoryDb:
    let
      db = ContentDB.new(config.dbDir.string)
      res = populateHistoryDb(db, config.dataFile.string)
    if res.isErr():
      fatal "Failed populating the history content db", error = $res.error
      quit 1

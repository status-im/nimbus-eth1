# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[os, enumutils],
  confutils,
  confutils/std/net,
  chronicles,
  chronicles/topics_registry,
  chronos,
  metrics,
  metrics/chronos_httpserver,
  json_rpc/clients/httpclient,
  results,
  stew/[byteutils, io2],
  eth/keys,
  eth/net/nat,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ./conf,
  ./network_metadata,
  ./common/common_utils,
  ./rpc/
    [rpc_web3_api, rpc_eth_api, rpc_discovery_api, rpc_portal_api, rpc_portal_debug_api],
  ./database/content_db,
  ./portal_node,
  ./version,
  ./logging

chronicles.formatIt(IoErrorCode):
  $it

func optionToOpt[T](o: Option[T]): Opt[T] =
  if o.isSome():
    Opt.some(o.unsafeGet())
  else:
    Opt.none(T)

proc run(config: PortalConf): PortalNode {.raises: [CatchableError].} =
  setupLogging(config.logLevel, config.logStdout, none(OutFile))

  notice "Launching Fluffy", version = fullVersionStr, cmdParams = commandLineParams()

  let rng = newRng()

  # Make sure dataDir exists
  let pathExists = createPath(config.dataDir.string)
  if pathExists.isErr():
    fatal "Failed to create data directory",
      dataDir = config.dataDir, error = pathExists.error
    quit 1

  ## Network configuration
  let
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

  case config.network
  of PortalNetwork.none:
    discard # don't connect to any network bootstrap nodes
  of PortalNetwork.mainnet:
    for enrURI in mainnetBootstrapNodes:
      let res = enr.Record.fromURI(enrURI)
      if res.isOk():
        bootstrapRecords.add(res.value)
  of PortalNetwork.angelfood:
    for enrURI in angelfoodBootstrapNodes:
      let res = enr.Record.fromURI(enrURI)
      if res.isOk():
        bootstrapRecords.add(res.value)

  ## Discovery v5 protocol setup
  let
    discoveryConfig =
      DiscoveryConfig.init(config.tableIpLimit, config.bucketIpLimit, config.bitsPerHop)
    d = newProtocol(
      netkey,
      extIp,
      Opt.none(Port),
      extUdpPort,
      # Note: The addition of default clientInfo to the ENR is a temporary
      # measure to easily identify & debug the clients used in the testnet.
      # Might make this into a, default off, cli option.
      localEnrFields = {"c": enrClientInfoShort},
      bootstrapRecords = bootstrapRecords,
      previousRecord = previousEnr,
      bindIp = bindIp,
      bindPort = udpPort,
      enrAutoUpdate = config.enrAutoUpdate,
      config = discoveryConfig,
      rng = rng,
    )

  d.open()

  ## Force pruning - optional
  if config.forcePrune:
    let db = ContentDB.new(
      config.dataDir / config.network.getDbDirectory() / "contentdb_" &
        d.localNode.id.toBytesBE().toOpenArray(0, 8).toHex(),
      storageCapacity = config.storageCapacityMB * 1_000_000,
      radiusConfig = config.radiusConfig,
      localId = d.localNode.id,
      manualCheckpoint = true,
    )

    let radius = db.estimateNewRadius(config.radiusConfig)
    # Note: In the case of dynamical radius this is all an approximation that
    # heavily relies on uniformly distributed content and thus will always
    # have an error margin, either down or up of the requested capacity.
    # TODO I: Perhaps we want to add an offset to counter the latter.
    # TODO II: Perhaps for dynamical radius, we want to also apply the vacuum
    # without the forcePrune flag and purely by checking the amount of free
    # space versus the pruning fraction. The problem with this is that the
    # vacuum will temporarily double the space usage (WAL + DB) and thus to do
    # this automatically without user requesting it could be dangerous.
    # TODO III: Adding Radius metadata to the db could be yet another way to
    # decide whether or not to force prune, instead of this flag.
    db.forcePrune(d.localNode.id, radius)
    db.close()

  ## Portal node setup
  let
    portalProtocolConfig = PortalProtocolConfig.init(
      config.tableIpLimit, config.bucketIpLimit, config.bitsPerHop, config.radiusConfig,
      config.disablePoke,
    )

    portalNodeConfig = PortalNodeConfig(
      accumulatorFile: config.accumulatorFile.optionToOpt().map(
          proc(v: InputFile): string =
            $v
        ),
      disableStateRootValidation: config.disableStateRootValidation,
      trustedBlockRoot: config.trustedBlockRoot.optionToOpt(),
      portalConfig: portalProtocolConfig,
      dataDir: string config.dataDir,
      storageCapacity: config.storageCapacityMB * 1_000_000,
    )
    node = PortalNode.new(
      config.network,
      portalNodeConfig,
      d,
      config.portalSubnetworks,
      bootstrapRecords = bootstrapRecords,
      rng = rng,
    )

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
      url = "http://" & $address & ":" & $port & "/metrics"

      server = MetricsHttpServerRef.new($address, port).valueOr:
        error "Could not instantiate metrics HTTP server", url, error
        quit QuitFailure

    info "Starting metrics HTTP server", url
    try:
      waitFor server.start()
    except MetricsError as exc:
      fatal "Could not start metrics HTTP server",
        url, error_msg = exc.msg, error_name = exc.name
      quit QuitFailure

  ## Start discovery v5 protocol and the Portal node.
  d.start()
  node.start()

  ## Start the JSON-RPC APIs

  proc setupRpcServer(
      rpcServer: RpcHttpServer | RpcWebSocketServer
  ) {.raises: [CatchableError].} =
    rpcServer.installDiscoveryApiHandlers(d)
    rpcServer.installWeb3ApiHandlers()
    if node.stateNetwork.isSome():
      rpcServer.installPortalApiHandlers(
        node.stateNetwork.value.portalProtocol, "state"
      )
    if node.historyNetwork.isSome():
      rpcServer.installEthApiHandlers(
        node.historyNetwork.value, node.beaconLightClient, node.stateNetwork
      )
      rpcServer.installPortalApiHandlers(
        node.historyNetwork.value.portalProtocol, "history"
      )
      rpcServer.installPortalDebugApiHandlers(
        node.historyNetwork.value.portalProtocol, "history"
      )
    if node.beaconNetwork.isSome():
      rpcServer.installPortalApiHandlers(
        node.beaconNetwork.value.portalProtocol, "beacon"
      )

    rpcServer.start()

  if config.rpcEnabled:
    let
      ta = initTAddress(config.rpcAddress, config.rpcPort)
      rpcHttpServer = RpcHttpServer.new()
    # Note: Set maxRequestBodySize to 4MB instead of 1MB as there are blocks
    # that reach that limit (in hex, for gossip method).
    rpcHttpServer.addHttpServer(ta, maxRequestBodySize = 4 * 1_048_576)

    setupRpcServer(rpcHttpServer)

  if config.wsEnabled:
    let
      ta = initTAddress(config.rpcAddress, config.wsPort)
      rpcWsServer = newRpcWebSocketServer(ta, compression = config.wsCompression)

    setupRpcServer(rpcWsServer)

  return node

when isMainModule:
  {.pop.}
  let config = PortalConf.load(
    version = clientName & " " & fullVersionStr & "\p\p" & nimBanner,
    copyrightBanner = copyrightBanner,
  )
  {.push raises: [].}

  let node =
    case config.cmd
    of PortalCmd.noCommand:
      run(config)

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()

    notice "Got interrupt, Fluffy shutting down..."
    node.stop()
    quit QuitSuccess

  setControlCHook(controlCHandler)

  runForever()

# nimbus_verified_proxy
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[options, os, strutils],
  chronicles,
  chronos,
  confutils,
  eth/common/[keys, eth_types_rlp],
  json_rpc/rpcproxy,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/[forks, beaconstate],
  beacon_chain/[conf, beacon_clock, buildinfo, nimbus_binary_common, process_state],
  ../execution_chain/common/common,
  ./nimbus_verified_proxy_conf,
  ./engine/engine,
  ./engine/genesis_params,
  ./engine/rpc_frontend,
  ./engine/header_store,
  ./engine/utils,
  ./engine/types,
  ./lc_backend,
  ./p2p_lc_backend,
  ./json_rpc_backend,
  ./json_rpc_frontend,
  ./op/op_anchor,
  ./op/op_chain_params,
  ./op/op_frontend,
  ../execution_chain/version_info

# error object to translate results to error
# NOTE: all results are translated to errors only in this file
# to allow effective usage of verified proxy code in other projects
# without the need of exceptions
type ProxyError = object of CatchableError

func getConfiguredChainId*(chain: Option[string]): UInt256 =
  let net = chain.get("mainnet").toLowerAscii()
  case net
  of "mainnet": 1.u256
  of "sepolia": 11155111.u256
  of "hoodi": 560048.u256
  else: 1.u256

proc startExecutionBackends(
    engine: RpcVerificationEngine, urls: seq[string], caps: BackendCapabilities
): Future[seq[JsonRpcClient]] {.async: (raises: [ProxyError, CancelledError]).} =
  var clients: seq[JsonRpcClient] = @[]

  for url in urls:
    let client = JsonRpcClient.init(url).valueOr:
      error "Error initializing backend client", error = error.errMsg
      continue

    let startRes = await client.start()
    if startRes.isErr():
      error "Error connecting to backend", url = url, error = startRes.error.errMsg
      continue

    engine.registerBackend(client.getExecutionApiBackend(), caps)
    clients.add(client)

  if clients.len == 0:
    raise newException(ProxyError, "Couldn't connect to any execution API backend")

  clients

proc startPrivateTxBackends(
    engine: RpcVerificationEngine, urls: seq[string]
): Future[seq[JsonRpcClient]] {.async: (raises: [ProxyError, CancelledError]).} =
  var clients: seq[JsonRpcClient] = @[]
  for url in urls:
    let client = JsonRpcClient.init(url).valueOr:
      error "Error initializing private tx client", error = error.errMsg
      continue

    let startRes = await client.start()

    if startRes.isErr():
      error "Error connecting to private tx backend",
        url = url, error = startRes.error.errMsg
      continue

    engine.registerBackend(
      client.getExecutionApiBackend(), BackendCapabilities({SendRawTransaction})
    )
    clients.add(client)

  if clients.len == 0:
    raise newException(ProxyError, "Couldn't connect to any private mempool backend")

proc startBeaconBackends(
    engine: RpcVerificationEngine, urls: UrlList
): Future[seq[BeaconApiRestClient]] {.async: (raises: [ProxyError, CancelledError]).} =
  var clients: seq[BeaconApiRestClient] = @[]

  for url in urls:
    let client = BeaconApiRestClient.init(engine.cfg, engine.forkDigests, url)

    let startRes = client.start()
    if startRes.isErr():
      error "Error connecting to backend", url = url, error = startRes.error.errMsg
      continue

    engine.registerBackend(client.getBeaconApiBackend(), fullBeaconCapabilities)
    clients.add(client)

  if clients.len == 0:
    raise newException(ProxyError, "Couldn't connect to any beacon API backend")

  clients

proc startP2PBeaconBackend(
    engine: RpcVerificationEngine, config: VerifiedProxyConf
): Future[Option[P2PLightClientBackend]] {.async: (raises: [CancelledError]).} =
  let
    networkName = config.eth2Network.get("mainnet")
    genesis = genesisParamsForNetwork(networkName)
    p2pConf = P2PBackendConf(
      cfg: engine.cfg,
      forkDigests: engine.forkDigests,
      getBeaconTime: engine.getBeaconTime,
      genesisValidatorsRoot: genesis.genesisValidatorsRoot,
      genesisBlockRoot: genesis.genesisBlockRoot,
      tcpPort: Port(config.p2pTcpPort),
      udpPort: Port(config.p2pUdpPort),
      maxPeers: config.p2pMaxPeers,
      bootstrapNodesFile: config.p2pBootstrapNodesFile,
      nat: config.p2pNat,
      network: networkName,
    )
    backend = P2PLightClientBackend.init(p2pConf).valueOr:
      error "Failed to create P2P light client node", err = error.errMsg
      return none(P2PLightClientBackend)

  let startRes = await backend.start()
  if startRes.isErr():
    error "Failed to start P2P light client backend", err = startRes.error.errMsg
    return none(P2PLightClientBackend)

  engine.registerBackend(backend.getBeaconApiBackend(), fullBeaconCapabilities)
  info "P2P light client backend started"
  some(backend)

proc startFrontends(
    frontend: ExecutionApiFrontend, urls: seq[string]
): seq[JsonRpcServer] {.raises: [ProxyError].} =
  var servers: seq[JsonRpcServer] = @[]

  for url in urls:
    let server = JsonRpcServer.init(url).valueOr:
      error "Error initializing frontend server", error = error.errMsg
      continue

    # inject frontend
    server.injectEngineFrontend(frontend)

    let status = server.start()
    if status.isErr():
      error "Error starting frontend server", error = status.error.errMsg
      continue

    servers.add(server)

  if servers.len == 0:
    raise newException(ProxyError, "Couldn't start any frontends for verified proxy")

  servers

proc run(
    config: VerifiedProxyConf
) {.async: (raises: [ProxyError, CancelledError]), gcsafe.} =
  {.gcsafe.}:
    setupLogging(config.logLevel, config.logFormat)

    try:
      notice "Launching Nimbus verified proxy",
        version = FullVersionStr, cmdParams = commandLineParams(), config
    except Exception:
      notice "commandLineParams() exception"

  let networkName = config.eth2Network.get("mainnet")

  # If an op-stack network is selected we run a secondary engine alongside the primary engine
  let opParams =
    if isOpNetwork(networkName):
      let p = opChainParamsForNetwork(networkName).valueOr:
        raise newException(ProxyError, "Unknown OP network: " & error)
      Opt.some(p)
    else:
      Opt.none(OpChainParams)

  let
    l1NetworkName =
      if opParams.isSome():
        opParams.get().l1Network
      else:
        networkName
    l1ChainId =
      if opParams.isSome():
        opParams.get().l1ChainId
      else:
        getConfiguredChainId(config.eth2Network)

  let
    engineConf = RpcVerificationEngineConf(
      chainId: l1ChainId,
      eth2Network: some(l1NetworkName),
      maxBlockWalk: config.maxBlockWalk,
      headerStoreLen: config.headerStoreLen,
      accountCacheLen: config.accountCacheLen,
      codeCacheLen: config.codeCacheLen,
      storageCacheLen: config.storageCacheLen,
      parallelBlockDownloads: config.parallelBlockDownloads,
      maxLightClientUpdates: config.maxLightClientUpdates,
      trustedBlockRoot: config.trustedBlockRoot,
      syncHeaderStore: config.syncHeaderStore,
    )
    engine = RpcVerificationEngine.init(engineConf).valueOr:
      raise newException(ProxyError, "Couldn't initialize verification engine")

  # sanity check
  if config.executionApiUrls.len <= 0:
    raise newException(ProxyError, "Need atleast one execution api url to be specified")

  if (config.beaconApiUrls.len <= 0) and (not config.p2pEnabled):
    raise newException(ProxyError, "Need atleast one beacon url or p2p enabled")

  let usePrivateTx = config.privateTxUrls.len > 0

  let regularCaps =
    if usePrivateTx:
      fullExecutionCapabilities - {SendRawTransaction}
    else:
      fullExecutionCapabilities

  let privateTxClients =
    if usePrivateTx:
      await startPrivateTxBackends(engine, config.privateTxUrls)
    else:
      @[]

  let execBackendClients =
    await startExecutionBackends(engine, config.executionApiUrls, regularCaps)
  let beaconBackendClients =
    if config.beaconApiUrls.len > 0:
      await startBeaconBackends(engine, config.beaconApiUrls)
    else:
      @[]

  let p2pBackend =
    if config.p2pEnabled:
      await startP2PBeaconBackend(engine, config)
    else:
      none(P2PLightClientBackend)

  let frontend = engine.getExecutionApiFrontend()
  let frontendServers = startFrontends(frontend, config.frontendUrls)

  # nil unless an OP network is configured (RpcVerificationEngine is a ref, so nil is the
  # natural "no L2 engine" state no Option wrapping needed)
  var
    l2Engine: RpcVerificationEngine
    opExecBackendClients: seq[JsonRpcClient]
    opFrontendServers: seq[JsonRpcServer]

  opParams.isErrOr:
    if config.opExecutionApiUrls.len <= 0:
      raise newException(
        ProxyError, "Need at least one L2 execution api url (--op-execution-api-url)"
      )

    # the L2 EVM follows the L1 fork schedule, so it uses the L1 network id
    let l2NetworkId = chainIdToNetworkId(l1ChainId).valueOr:
      raise newException(
        ProxyError, "Couldn't derive the L2 network id from the L1 chain id"
      )

    l2Engine = RpcVerificationEngine.initCore(
      chainId = value.l2ChainId,
      networkId = l2NetworkId,
      maxBlockWalk = config.maxBlockWalk,
      parallelBlockDownloads = config.parallelBlockDownloads,
      headerStoreLen = config.headerStoreLen,
      accountCacheLen = config.accountCacheLen,
      codeCacheLen = config.codeCacheLen,
      storageCacheLen = config.storageCacheLen,
    ).valueOr:
      raise newException(ProxyError, "Couldn't initialize OP verification engine")

    opExecBackendClients = await startExecutionBackends(
      l2Engine, config.opExecutionApiUrls, fullExecutionCapabilities
    )

    let opFrontend = getExecutionApiFrontend(l2Engine, engine)
    opFrontendServers = startFrontends(opFrontend, config.opFrontendUrls)

  try:
    while true:
      await sleepAsync(engine.timeParams.SLOT_DURATION)

      let syncRes = await engine.syncOnce()
      if syncRes.isErr():
        error "LC sync failed", error = syncRes.error.errMsg

      opParams.isErrOr:
        let opRes = await l2Engine.opSyncOnce(engine)
        if opRes.isErr():
          error "OP sync failed", error = opRes.error.errMsg
  except CancelledError as e:
    debug "proxy loop cancelled"
    for s in frontendServers:
      await s.stop()
    for s in opFrontendServers:
      await s.stop()
    for c in execBackendClients:
      await c.stop()
    for c in opExecBackendClients:
      await c.stop()
    for c in beaconBackendClients:
      await c.stop()
    for c in privateTxClients:
      await c.stop()
    if p2pBackend.isSome():
      await p2pBackend.get().stop()
    raise e

when isMainModule:
  const
    banner = "Nimbus Verified Proxy " & FullVersionStr
    copyright =
      "Copyright (c) 2022-" & compileYear & " Status Research & Development GmbH"

  var config = VerifiedProxyConf.loadWithBanners(banner, copyright, [], true).valueOr:
    writePanicLine error # Logging not yet set up
    quit QuitFailure

  ProcessState.setupStopHandlers()
  ProcessState.notifyRunning()

  let runFut = run(config)

  while not (
    ProcessState.stopIt(notice("Triggering a shut down", reason = it)) or
    runFut.finished()
  )
  :
    poll()

  # if runFut didn't finish process must have been stopped
  if not runFut.finished:
    runFut.cancelSoon()

  try:
    # critical that we waitFor here, it will propagate the error
    waitFor runFut
  except CancelledError:
    notice "Shutdown complete"
  except ProxyError as e:
    fatal "Proxy error", error = e.msg
    quit QuitFailure
  except CatchableError as e:
    fatal "Unexpected error", error = e.msg
    quit QuitFailure

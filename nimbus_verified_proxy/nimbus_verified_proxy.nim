# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[os, strutils],
  chronicles,
  chronos,
  confutils,
  eth/common/[keys, eth_types_rlp],
  json_rpc/rpcproxy,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/beaconstate,
  beacon_chain/conf,
  beacon_chain/[beacon_clock, buildinfo, nimbus_binary_common],
  ../execution_chain/common/common,
  ./nimbus_verified_proxy_conf,
  ./engine/engine,
  ./engine/header_store,
  ./engine/utils,
  ./engine/types,
  ./lc/lc,
  ./json_lc_backend,
  ./json_rpc_backend,
  ./json_rpc_frontend,
  ../execution_chain/version_info

proc verifyChainId(
    engine: RpcVerificationEngine
): Future[void] {.async: (raises: []).} =
  let providerId =
    try:
      await engine.backend.eth_chainId()
    except CatchableError:
      0.u256

  # This is a chain/network mismatch error between the Nimbus verified proxy and
  # the application using it. Fail fast to avoid misusage. The user must fix
  # the configuration.
  if engine.chainId != providerId:
    fatal "The specified data provider serves data for a different chain",
      expectedChain = engine.chainId, providerChain = providerId
    quit 1

func getConfiguredChainId(networkMetadata: Eth2NetworkMetadata): UInt256 =
  if networkMetadata.eth1Network.isSome():
    let
      net = networkMetadata.eth1Network.get()
      chainId =
        case net
        of mainnet: 1.u256
        of sepolia: 11155111.u256
        of holesky: 17000.u256
        of hoodi: 560048.u256
    return chainId
  else:
    return networkMetadata.cfg.DEPOSIT_CHAIN_ID.u256

proc connectLCToEngine*(lightClient: LightClient, engine: RpcVerificationEngine) =
  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(finalizedHeader):
      when lcDataFork > LightClientDataFork.Altair:
        info "New LC finalized header", finalized_header = shortLog(forkyHeader)
        let res = engine.headerStore.updateFinalized(finalizedHeader)

        if res.isErr():
          error "finalized header update error", error = res.error()
      else:
        error "pre-bellatrix light client headers do not have the execution payload header"

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.Altair:
        info "New LC optimistic header", optimistic_header = shortLog(forkyHeader)
        let res = engine.headerStore.add(optimisticHeader)

        if res.isErr():
          error "header store add error", error = res.error()
      else:
        error "pre-bellatrix light client headers do not have the execution payload header"

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot

proc run(
    config: VerifiedProxyConf
) {.async: (raises: [ValueError, CatchableError]), gcsafe.} =
  {.gcsafe.}:
    setupLogging(config.logLevel, config.logStdout)

    try:
      notice "Launching Nimbus verified proxy",
        version = FullVersionStr, cmdParams = commandLineParams(), config
    except Exception:
      notice "commandLineParams() exception"

  let
    engineConf = RpcVerificationEngineConf(
      chainId: getConfiguredChainId(config.eth2Network),
      maxBlockWalk: config.maxBlockWalk,
      headerStoreLen: config.headerStoreLen,
      accountCacheLen: config.accountCacheLen,
      codeCacheLen: config.codeCacheLen,
      storageCacheLen: config.storageCacheLen,
    )
    engine = RpcVerificationEngine.init(engineConf)
    lc = LightClient.new(config.eth2Network, some config.trustedBlockRoot)

    #initialize frontend and backend for JSON-RPC
    jsonRpcClient = JsonRpcClient.init(config.backendUrl)
    jsonRpcServer = JsonRpcServer.init(config.frontendUrl)

    # initialize backend for light client updates
    lcRestClient = LCRestClient.new(lc.cfg, lc.forkDigests)

  # connect light client to LC by registering on header methods 
  # to use engine header store
  connectLCToEngine(lc, engine)

  # add light client backend
  lc.setBackend(lcRestClient.getEthLCBackend())

  # the backend only needs the url of the RPC provider
  engine.backend = jsonRpcClient.getEthApiBackend()
  # inject frontend
  jsonRpcServer.injectEngineFrontend(engine.frontend)

  # start frontend and backend for JSON-RPC
  var status = await jsonRpcClient.start()
  if status.isErr():
    raise newException(ValueError, status.error)

  status = jsonRpcServer.start()
  if status.isErr():
    raise newException(ValueError, status.error)

  # adding endpoints will also start the backend
  lcRestClient.addEndpoints(config.lcEndpoints)

  # verify chain id that the proxy is connected to
  await engine.verifyChainId()

  # this starts the light client manager which is
  # an endless loop
  try:
    await lc.start()
  except CancelledError as e:
    debugEcho e.msg

# noinline to keep it in stack traces
proc main() {.noinline, raises: [CatchableError].} =
  const
    banner = "Nimbus Verified Proxy " & FullVersionStr
    copyright =
      "Copyright (c) 2022-" & compileYear & " Status Research & Development GmbH"

  var config = VerifiedProxyConf.loadWithBanners(banner, copyright, [], true).valueOr:
    writePanicLine error # Logging not yet set up
    quit QuitFailure

  waitFor run(config)

when isMainModule:
  main()

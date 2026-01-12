# nimbus_verified_proxy
# Copyright (c) 2022-2026 Status Research & Development GmbH
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
  ./lc_backend,
  ./json_rpc_backend,
  ./json_rpc_frontend,
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

  let
    engineConf = RpcVerificationEngineConf(
      chainId: getConfiguredChainId(config.eth2Network),
      maxBlockWalk: config.maxBlockWalk,
      headerStoreLen: config.headerStoreLen,
      accountCacheLen: config.accountCacheLen,
      codeCacheLen: config.codeCacheLen,
      storageCacheLen: config.storageCacheLen,
      parallelBlockDownloads: config.parallelBlockDownloads,
    )
    engine = RpcVerificationEngine.init(engineConf).valueOr:
      raise newException(ProxyError, "Couldn't initialize verification engine")
    lc = LightClient.new(config.eth2Network, some config.trustedBlockRoot)

    #initialize frontend and backend for JSON-RPC
    jsonRpcClientPool = JsonRpcClientPool.new()
    jsonRpcServer = JsonRpcServer.init(config.frontendUrl).valueOr:
      raise newException(ProxyError, "Couldn't initialize the server end of proxy")

    # initialize backend for light client updates
    lcRestClientPool = LCRestClientPool.new(lc.cfg, lc.forkDigests)

  if (await jsonRpcClientPool.addEndpoints(config.backendUrls)).isErr():
    raise newException(ProxyError, "Couldn't add endpoints for the web3 backend")

  # connect light client to LC by registering on header methods 
  # to use engine header store
  connectLCToEngine(lc, engine)
  lc.trustedBlockRoot = some config.trustedBlockRoot

  # add light client backend
  lc.setBackend(lcRestClientPool.getEthLCBackend())

  # the backend only needs the url of the RPC provider
  engine.backend = jsonRpcClientPool.getEthApiBackend()
  # inject frontend
  jsonRpcServer.injectEngineFrontend(engine.frontend)

  let status = jsonRpcServer.start()
  if status.isErr():
    raise newException(ProxyError, status.error.errMsg)

  # adding endpoints will also start the backend
  if lcRestClientPool.addEndpoints(config.beaconApiUrls).isErr():
    raise newException(ProxyError, "Couldn't add endpoints for light client queries")

  # this starts the light client manager which is
  # an endless loop
  try:
    await lc.start()
  except CancelledError as e:
    debug "light client cancelled"
    raise e

# noinline to keep it in stack traces
proc main() {.noinline, raises: [ProxyError, CancelledError].} =
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

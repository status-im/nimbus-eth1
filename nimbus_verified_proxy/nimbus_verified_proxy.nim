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

proc run*(
    config: VerifiedProxyConf, ctx: ptr Context
) {.raises: [CatchableError], gcsafe.} =
  {.gcsafe.}:
    setupLogging(config.logLevel, config.logStdout)

    try:
      notice "Launching Nimbus verified proxy",
        version = FullVersionStr, cmdParams = commandLineParams(), config
    except Exception:
      notice "commandLineParams() exception"

proc startLightClient*(config: VerifiedProxyConf, engine: RpcVerificationEngine) {.async.} =
  # load constants and metadata for the selected chain
  let metadata = loadEth2Network(config.eth2Network)

  # just for short hand convenience
  template cfg(): auto =
    metadata.cfg

  # initialize beacon node genesis data, beacon clock and forkDigests
  let
    genesisState =
      try:
        template genesisData(): auto =
          metadata.genesis.bakedBytes

        newClone(
          readSszForkedHashedBeaconState(
            cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)
          )
        )
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    # getStateField reads seeks info directly from a byte array
    # get genesis time and instantiate the beacon clock
    genesisTime = getStateField(genesisState[], genesis_time)
    beaconClock = BeaconClock.init(cfg.timeParams, genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure

    # get the function that itself get the current beacon time
    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root = getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

    rng = keys.newRng()

    # light client is set to optimistic finalization mode
    lightClient = LightClient.new(
      rng, cfg, forkDigests, getBeaconTime, genesis_validators_root,
      LightClientFinalizationMode.Optimistic,
    )

    # REST client for json LC updates
    lcRestClient = LCRestClient.new(cfg, forkDigests)

  debugEcho config.lcEndpoint

  # add endpoints to the client
  lcRestClient.addEndpoint(config.lcEndpoint)
  lightClient.setBackend(lcRestClient.getEthLCBackend())

  # verify chain id that the proxy is connected to
  waitFor engine.verifyChaindId()

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

  # start the light client
  lightClient.start()

  # run an infinite loop and wait for a stop signal
  while true:
    poll()
    if ctx != nil and ctx.stop:
      # Cleanup
      waitFor lcRestClient.closeAll()
      waitFor jsonRpcClient.stop()
      waitFor jsonRpcServer.stop()
      ctx.cleanup()
      # Notify client that cleanup is finished
      ctx.onHeader(nil, 2)
      break

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

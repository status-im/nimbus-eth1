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
  beacon_chain/gossip_processing/optimistic_processor,
  beacon_chain/networking/network_metadata,
  beacon_chain/networking/topic_params,
  beacon_chain/spec/beaconstate,
  beacon_chain/[beacon_clock, buildinfo, light_client, nimbus_binary_common],
  ../execution_chain/rpc/cors,
  ../execution_chain/common/common,
  ./types,
  ./rpc/evm,
  ./rpc/rpc_eth_api,
  ./nimbus_verified_proxy_conf,
  ./header_store,
  ./rpc_api_backend,
  ../execution_chain/version_info

type OnHeaderCallback* = proc(s: cstring, t: int) {.cdecl, raises: [], gcsafe.}
type Context* = object
  thread*: Thread[ptr Context]
  configJson*: cstring
  stop*: bool
  onHeader*: OnHeaderCallback

proc cleanup*(ctx: ptr Context) =
  dealloc(ctx.configJson)
  freeShared(ctx)

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

func chainIdToNetworkId(chainId: UInt256): Result[UInt256, string] =
  if chainId == 1.u256:
    ok(1.u256)
  elif chainId == 11155111.u256:
    ok(11155111.u256)
  elif chainId == 17000.u256:
    ok(17000.u256)
  elif chainId == 560048.u256:
    ok(560048.u256)
  else:
    return err("Unknown chainId")

proc run*(
    config: VerifiedProxyConf, ctx: ptr Context
) {.raises: [CatchableError], gcsafe.} =
  {.gcsafe.}:
    setupLogging(config.logLevel, config.logStdout)

    try:
      notice "Launching Nimbus verified proxy",
        version = fullVersionStr, cmdParams = commandLineParams(), config
    except Exception:
      notice "commandLineParams() exception"

  # load constants and metadata for the selected chain
  let metadata = loadEth2Network(config.eth2Network)

  let
    chainId = getConfiguredChainId(metadata)
    authHooks = @[httpCors(@[])] # TODO: for now we serve all cross origin requests
    # TODO: write a comment
    clientConfig = config.web3url.asClientConfig()

    rpcProxy = RpcProxy.new(
      [initTAddress(config.rpcAddress, config.rpcPort)], clientConfig, authHooks
    )

    # header cache contains headers downloaded from p2p
    headerStore = HeaderStore.new(config.cacheLen)

    # TODO: add config object to verified proxy for future config options
    verifiedProxy =
      VerifiedRpcProxy.init(rpcProxy, headerStore, chainId, config.maxBlockWalk)

    networkId = chainIdToNetworkId(chainId).valueOr:
      raise newException(ValueError, error)

  verifiedProxy.evm = AsyncEvm.init(verifiedProxy.toAsyncEvmStateBackend(), networkId)
  verifiedProxy.rpcClient = verifiedProxy.initNetworkApiBackend()

  # add handlers that verify RPC calls /rpc/rpc_eth_api.nim
  verifiedProxy.installEthApiHandlers()

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
    beaconClock = BeaconClock.init(genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure

    # get the function that itself get the current beacon time
    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root = getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

  # transform the config to fit as a light client config and as a p2p node(Eth2Node) config
  var lcConfig = config.asLightClientConf()
  for node in metadata.bootstrapNodes:
    lcConfig.bootstrapNodes.add node

  # create new network keys, create a p2p node(Eth2Node) and create a light client
  let
    rng = keys.newRng()

    netKeys = getRandomNetKeys(rng[])

    network = createEth2Node(
      rng, lcConfig, netKeys, cfg, forkDigests, getBeaconTime, genesis_validators_root
    )

    # light client is set to optimistic finalization mode
    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime, genesis_validators_root,
      LightClientFinalizationMode.Optimistic,
    )

  # registerbasic p2p protocols for maintaing peers ping/status/get_metadata/... etc.
  network.registerProtocol(
    PeerSync,
    PeerSync.NetworkState.init(cfg, forkDigests, genesisBlockRoot, getBeaconTime),
  )

  # start the p2p network and rpcProxy
  waitFor network.startListening()
  waitFor network.start()
  waitFor rpcProxy.start()

  # verify chain id that the proxy is connected to
  waitFor verifiedProxy.verifyChaindId()

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(finalizedHeader):
      when lcDataFork > LightClientDataFork.Altair:
        info "New LC finalized header", finalized_header = shortLog(forkyHeader)
        let res = headerStore.updateFinalized(finalizedHeader)

        if res.isErr():
          error "finalized header update error", error = res.error()

        if ctx != nil:
          try:
            ctx.onHeader(cstring(Json.encode(forkyHeader)), 0)
          except SerializationError as e:
            error "finalizedHeaderCallback exception", error = e.msg
      else:
        error "pre-bellatrix light client headers do not have the execution payload header"

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.Altair:
        info "New LC optimistic header", optimistic_header = shortLog(forkyHeader)
        let res = headerStore.add(optimisticHeader)

        if res.isErr():
          error "header store add error", error = res.error()

        if ctx != nil:
          try:
            ctx.onHeader(cstring(Json.encode(forkyHeader)), 1)
          except SerializationError as e:
            error "optimisticHeaderCallback exception", error = e.msg
      else:
        error "pre-bellatrix light client headers do not have the execution payload header"

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot
  lightClient.installMessageValidators()

  func shouldSyncOptimistically(wallSlot: Slot): bool =
    let optimisticHeader = lightClient.optimisticHeader
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        # Check whether light client has synced sufficiently close to wall slot
        const maxAge = 2 * SLOTS_PER_EPOCH
        forkyHeader.beacon.slot >= max(wallSlot, maxAge.Slot) - maxAge
      else:
        false

  var blocksGossipState: GossipState
  proc updateBlocksGossipStatus(slot: Slot) =
    let
      isBehind = not shouldSyncOptimistically(slot)

      targetGossipState = getTargetGossipState(slot.epoch, cfg, isBehind)

    template currentGossipState(): auto =
      blocksGossipState

    if currentGossipState == targetGossipState:
      return

    if currentGossipState.card == 0 and targetGossipState.card > 0:
      debug "Enabling blocks topic subscriptions", wallSlot = slot, targetGossipState
    elif currentGossipState.card > 0 and targetGossipState.card == 0:
      debug "Disabling blocks topic subscriptions", wallSlot = slot
    else:
      # Individual forks added / removed
      discard

    let
      newGossipEpochs = targetGossipState - currentGossipState
      oldGossipEpochs = currentGossipState - targetGossipState

    for gossipEpoch in oldGossipEpochs:
      let forkDigest = forkDigests[].atEpoch(gossipEpoch, cfg)
      network.unsubscribe(getBeaconBlocksTopic(forkDigest))

    for gossipEpoch in newGossipEpochs:
      let forkDigest = forkDigests[].atEpoch(gossipEpoch, cfg)
      network.subscribe(
        getBeaconBlocksTopic(forkDigest),
        getBlockTopicParams(),
        enableTopicMetrics = true,
      )

    blocksGossipState = targetGossipState

  proc updateGossipStatus(time: Moment) =
    let wallSlot = getBeaconTime().slotOrZero()
    updateBlocksGossipStatus(wallSlot + 1)
    lightClient.updateGossipStatus(wallSlot + 1)

  # updates gossip status every second every second
  proc runOnSecondLoop() {.async.} =
    let sleepTime = chronos.seconds(1)
    while true:
      let start = chronos.now(chronos.Moment)
      await chronos.sleepAsync(sleepTime)
      let afterSleep = chronos.now(chronos.Moment)
      let sleepTime = afterSleep - start
      updateGossipStatus(start)
      let finished = chronos.now(chronos.Moment)
      let processingTime = finished - afterSleep
      trace "onSecond task completed", sleepTime, processingTime

  # update gossip status before starting the light client
  updateGossipStatus(Moment.now())
  # start the light client
  lightClient.start()

  # launch a async routine
  asyncSpawn runOnSecondLoop()

  # run an infinite loop and wait for a stop signal
  while true:
    poll()
    if ctx != nil and ctx.stop:
      # Cleanup
      waitFor network.stop()
      waitFor rpcProxy.stop()
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

  run(config, nil)

when isMainModule:
  main()

# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[atomics, json, os, strutils],
  chronicles,
  chronos,
  confutils,
  eth/keys,
  json_rpc/rpcproxy,
  beacon_chain/el/el_manager,
  beacon_chain/gossip_processing/optimistic_processor,
  beacon_chain/networking/topic_params,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common, version],
  ../nimbus/rpc/cors,
  "."/rpc/[rpc_eth_api, rpc_utils],
  ./nimbus_verified_proxy_conf,
  ./block_cache

from beacon_chain/gossip_processing/block_processor import newExecutionPayload
from beacon_chain/gossip_processing/eth2_processor import toValidationResult

type OnHeaderCallback* = proc(s: cstring, t: int) {.cdecl, raises: [], gcsafe.}
type Context* = object
  thread*: Thread[ptr Context]
  configJson*: cstring
  stop*: bool
  onHeader*: OnHeaderCallback

proc cleanup*(ctx: ptr Context) =
  dealloc(ctx.configJson)
  freeShared(ctx)

func getConfiguredChainId(networkMetadata: Eth2NetworkMetadata): Quantity =
  if networkMetadata.eth1Network.isSome():
    let
      net = networkMetadata.eth1Network.get()
      chainId =
        case net
        of mainnet: 1.Quantity
        of goerli: 5.Quantity
        of sepolia: 11155111.Quantity
        of holesky: 17000.Quantity
    return chainId
  else:
    return networkMetadata.cfg.DEPOSIT_CHAIN_ID.Quantity

proc run*(
    config: VerifiedProxyConf, ctx: ptr Context
) {.raises: [CatchableError], gcsafe.} =
  var headerCallback: OnHeaderCallback
  if ctx != nil:
    headerCallback = ctx.onHeader

  # Required as both Eth2Node and LightClient requires correct config type
  var lcConfig = config.asLightClientConf()

  {.gcsafe.}:
    setupLogging(config.logLevel, config.logStdout, none(OutFile))

    try:
      notice "Launching Nimbus verified proxy",
        version = fullVersionStr, cmdParams = commandLineParams(), config
    except Exception:
      notice "commandLineParams() exception"

  let
    metadata = loadEth2Network(config.eth2Network)
    chainId = getConfiguredChainId(metadata)

  for node in metadata.bootstrapNodes:
    lcConfig.bootstrapNodes.add node

  template cfg(): auto =
    metadata.cfg

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

    genesisTime = getStateField(genesisState[], genesis_time)
    beaconClock = BeaconClock.init(genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure

    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root = getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

    rng = keys.newRng()

    netKeys = getRandomNetKeys(rng[])

    network = createEth2Node(
      rng, lcConfig, netKeys, cfg, forkDigests, getBeaconTime, genesis_validators_root
    )

    blockCache = BlockCache.new(uint32(64))

    # TODO: for now we serve all cross origin requests
    authHooks = @[httpCors(@[])]

    clientConfig = config.web3url.asClientConfig()

    rpcProxy = RpcProxy.new(
      [initTAddress(config.rpcAddress, config.rpcPort)], clientConfig, authHooks
    )

    verifiedProxy = VerifiedRpcProxy.new(rpcProxy, blockCache, chainId)

    optimisticHandler = proc(
        signedBlock: ForkedMsgTrustedSignedBeaconBlock
    ): Future[void] {.async: (raises: [CancelledError]).} =
      notice "New LC optimistic block",
        opt = signedBlock.toBlockId(), wallSlot = getBeaconTime().slotOrZero
      withBlck(signedBlock):
        when consensusFork >= ConsensusFork.Bellatrix:
          if forkyBlck.message.is_execution_block:
            template payload(): auto =
              forkyBlck.message.body.execution_payload

            blockCache.add(asExecutionData(payload.asEngineExecutionPayload()))
        else:
          discard
      return

    optimisticProcessor = initOptimisticProcessor(getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime, genesis_validators_root,
      LightClientFinalizationMode.Optimistic,
    )

  verifiedProxy.installEthApiHandlers()

  info "Listening to incoming network requests"
  network.registerProtocol(
    PeerSync,
    PeerSync.NetworkState.init(cfg, forkDigests, genesisBlockRoot, getBeaconTime),
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.phase0),
    proc(signedBlock: phase0.SignedBeaconBlock): ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock))
    ,
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.altair),
    proc(signedBlock: altair.SignedBeaconBlock): ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock))
    ,
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.bellatrix),
    proc(signedBlock: bellatrix.SignedBeaconBlock): ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock))
    ,
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.capella),
    proc(signedBlock: capella.SignedBeaconBlock): ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock))
    ,
  )
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.deneb),
    proc(signedBlock: deneb.SignedBeaconBlock): ValidationResult =
      toValidationResult(optimisticProcessor.processSignedBeaconBlock(signedBlock))
    ,
  )
  lightClient.installMessageValidators()

  waitFor network.startListening()
  waitFor network.start()
  waitFor rpcProxy.start()
  waitFor verifiedProxy.verifyChaindId()

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(finalizedHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC finalized header", finalized_header = shortLog(forkyHeader)
        if headerCallback != nil:
          try:
            headerCallback(Json.encode(forkyHeader), 0)
          except SerializationError as e:
            notice "finalizedHeaderCallback exception"

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: ForkedLightClientHeader
  ) =
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC optimistic header", optimistic_header = shortLog(forkyHeader)
        optimisticProcessor.setOptimisticHeader(forkyHeader.beacon)
        if headerCallback != nil:
          try:
            headerCallback(Json.encode(forkyHeader), 1)
          except SerializationError as e:
            notice "optimisticHeaderCallback exception"

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot

  func shouldSyncOptimistically(wallSlot: Slot): bool =
    let optimisticHeader = lightClient.optimisticHeader
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        # Check whether light client has synced sufficiently close to wall slot
        const maxAge = 2 * SLOTS_PER_EPOCH
        forkyHeader.beacon.slot >= max(wallSlot, maxAge.Slot) - maxAge
      else:
        false

  var blocksGossipState: GossipState = {}
  proc updateBlocksGossipStatus(slot: Slot) =
    let
      isBehind = not shouldSyncOptimistically(slot)

      targetGossipState = getTargetGossipState(
        slot.epoch, cfg.ALTAIR_FORK_EPOCH, cfg.BELLATRIX_FORK_EPOCH,
        cfg.CAPELLA_FORK_EPOCH, cfg.DENEB_FORK_EPOCH, cfg.ELECTRA_FORK_EPOCH, isBehind,
      )

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
      newGossipForks = targetGossipState - currentGossipState
      oldGossipForks = currentGossipState - targetGossipState

    for gossipFork in oldGossipForks:
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
      network.unsubscribe(getBeaconBlocksTopic(forkDigest))

    for gossipFork in newGossipForks:
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
      network.subscribe(
        getBeaconBlocksTopic(forkDigest), blocksTopicParams, enableTopicMetrics = true
      )

    blocksGossipState = targetGossipState

  proc onSecond(time: Moment) =
    let wallSlot = getBeaconTime().slotOrZero()
    updateBlocksGossipStatus(wallSlot + 1)
    lightClient.updateGossipStatus(wallSlot + 1)

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
  lightClient.start()

  asyncSpawn runOnSecondLoop()
  while true:
    poll()
    if ctx != nil and ctx.stop:
      # Cleanup
      waitFor network.stop()
      waitFor rpcProxy.stop()
      ctx.cleanup()
      # Notify client that cleanup is finished
      headerCallback(nil, 2)
      break

when isMainModule:
  {.pop.}
  var config =
    makeBannerAndConfig("Nimbus verified proxy " & fullVersionStr, VerifiedProxyConf)
  {.push raises: [].}
  run(config, nil)

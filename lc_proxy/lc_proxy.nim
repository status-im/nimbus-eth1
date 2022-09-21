# light client proxy
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This implements the pre-release proposal of the libp2p based light client sync
# protocol. See https://github.com/ethereum/consensus-specs/pull/2802

{.push raises: [Defect].}

import
  std/[os, strutils],
  chronicles, chronicles/chronos_tools, chronos,
  eth/keys,
  json_rpc/[rpcserver, rpcclient],
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/gossip_processing/optimistic_processor,
  beacon_chain/networking/topic_params,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common, version],
  ./rpc/rpc_eth_lc_api,
  ./lc_proxy_conf

from beacon_chain/consensus_object_pools/consensus_manager import runForkchoiceUpdated
from beacon_chain/gossip_processing/block_processor import newExecutionPayload
from beacon_chain/gossip_processing/eth2_processor import toValidationResult

proc initRpcClient(config: LcProxyConf): Future[RpcClient] {.async.} =
  case config.web3ClientConfig.kind
  of WsClient:
    let wssClient = newRpcWebSocketClient()
    await wssClient.connect(config.web3ClientConfig.url)
    return wssClient
  of HttpClient:
    let httpClient = newRpcHttpClient()
    await httpClient.connect(config.web3ClientConfig.url)
    return httpClient

func getConfiguredChainId(networkMetadata: Eth2NetworkMetadata): Quantity =
  if networkMetadata.eth1Network.isSome():
    let
      net = networkMetadata.eth1Network.get()
      chainId = case net
        of mainnet: 1.Quantity
        of ropsten: 3.Quantity
        of rinkeby: 4.Quantity
        of goerli:  5.Quantity
        of sepolia: 11155111.Quantity
    return chainId
  else:
    return networkMetadata.cfg.DEPOSIT_CHAIN_ID.Quantity

# TODO Find what can throw exception
proc run() {.raises: [Exception, Defect].} =
  {.pop.}
  var config = makeBannerAndConfig(
    "Nimbus light client " & fullVersionStr, LcProxyConf)
  {.push raises: [Defect].}

  # Required as both Eth2Node and LightClient requires correct config type
  var lcConfig = config.asLightClientConf()

  setupLogging(config.logLevel, config.logStdout, config.logFile)

  notice "Launching light client proxy",
    version = fullVersionStr, cmdParams = commandLineParams(), config

  let
    metadata = loadEth2Network(config.eth2Network)
    chainId = getConfiguredChainId(metadata)

  for node in metadata.bootstrapNodes:
    lcConfig.bootstrapNodes.add node

  template cfg(): auto = metadata.cfg

  let
    genesisState =
      try:
        template genesisData(): auto = metadata.genesisData
        newClone(readSszForkedHashedBeaconState(
          cfg, genesisData.toOpenArrayByte(genesisData.low, genesisData.high)))
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    beaconClock = BeaconClock.init(getStateField(genesisState[], genesis_time))

    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root =
      getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

    rng = keys.newRng()

    netKeys = getRandomNetKeys(rng[])

    network = createEth2Node(
      rng, lcConfig, netKeys, cfg,
      forkDigests, getBeaconTime, genesis_validators_root
    )

    rpcClient = waitFor initRpcClient(config)

    rpcHttpServer = newRpcHttpServer(
      [initTAddress(config.rpcAddress, config.rpcPort)]
    )

    lcProxy = LightClientRpcProxy.new(rpcHttpServer, rpcClient, chainId)

    optimisticHandler = proc(signedBlock: ForkedMsgTrustedSignedBeaconBlock):
        Future[void] {.async.} =
      notice "New LC optimistic block",
        opt = signedBlock.toBlockId(),
        wallSlot = getBeaconTime().slotOrZero
      withBlck(signedBlock):
        when stateFork >= BeaconStateFork.Bellatrix:
          if blck.message.is_execution_block:
            template payload(): auto = blck.message.body.execution_payload
            lcProxy.executionPayload.ok payload.asEngineExecutionPayload()
        else: discard
      return

    optimisticProcessor = initOptimisticProcessor(
      getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Optimistic)

  lcProxy.installEthApiHandlers()

  info "Listening to incoming network requests"
  network.initBeaconSync(cfg, forkDigests, genesisBlockRoot, getBeaconTime)
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.phase0),
    proc (signedBlock: phase0.SignedBeaconBlock): ValidationResult =
      toValidationResult(
        optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.altair),
    proc (signedBlock: altair.SignedBeaconBlock): ValidationResult =
      toValidationResult(
        optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  network.addValidator(
    getBeaconBlocksTopic(forkDigests.bellatrix),
    proc (signedBlock: bellatrix.SignedBeaconBlock): ValidationResult =
      toValidationResult(
        optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  lightClient.installMessageValidators()

  waitFor network.startListening()
  waitFor network.start()
  rpcHttpServer.start()
  waitFor lcProxy.verifyChaindId()

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: BeaconBlockHeader) =
    info "New LC finalized header",
      finalized_header = shortLog(finalizedHeader)

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: BeaconBlockHeader) =
    info "New LC optimistic header",
      optimistic_header = shortLog(optimisticHeader)
    optimisticProcessor.setOptimisticHeader(optimisticHeader)

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot

  func shouldSyncOptimistically(wallSlot: Slot): bool =
    # Check whether light client is used
    let optimisticHeader = lightClient.optimisticHeader.valueOr:
      return false

    # Check whether light client has synced sufficiently close to wall slot
    const maxAge = 2 * SLOTS_PER_EPOCH
    if optimisticHeader.slot < max(wallSlot, maxAge.Slot) - maxAge:
      return false

    true

  var blocksGossipState: GossipState = {}
  proc updateBlocksGossipStatus(slot: Slot) =
    let
      isBehind = not shouldSyncOptimistically(slot)

      targetGossipState = getTargetGossipState(
        slot.epoch, cfg.ALTAIR_FORK_EPOCH, cfg.BELLATRIX_FORK_EPOCH, isBehind)

    template currentGossipState(): auto = blocksGossipState
    if currentGossipState == targetGossipState:
      return

    if currentGossipState.card == 0 and targetGossipState.card > 0:
      debug "Enabling blocks topic subscriptions",
        wallSlot = slot, targetGossipState
    elif currentGossipState.card > 0 and targetGossipState.card == 0:
      debug "Disabling blocks topic subscriptions",
        wallSlot = slot
    else:
      # Individual forks added / removed
      discard

    let
      newGossipForks = targetGossipState - currentGossipState
      oldGossipForks = currentGossipState - targetGossipState

    for gossipFork in oldGossipForks:
      let forkDigest = forkDigests[].atStateFork(gossipFork)
      network.unsubscribe(getBeaconBlocksTopic(forkDigest))

    for gossipFork in newGossipForks:
      let forkDigest = forkDigests[].atStateFork(gossipFork)
      network.subscribe(
        getBeaconBlocksTopic(forkDigest), blocksTopicParams,
        enableTopicMetrics = true)

    blocksGossipState = targetGossipState

  var nextExchangeTransitionConfTime: Moment

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

when isMainModule:
  run()

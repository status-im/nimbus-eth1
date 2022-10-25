# nimbus_verified_proxy
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[json, os, strutils],
  chronicles, chronicles/chronos_tools, chronos, confutils,
  eth/keys,
  json_rpc/rpcproxy,
  beacon_chain/eth1/eth1_monitor,
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

type OnHeaderCallback* = proc (s: cstring) {.cdecl.}

var optimisticHeaderCallback : OnHeaderCallback = nil
var finalizedHeaderCallback : OnHeaderCallback = nil
proc setOptimisticHeaderCallback*(cb: OnHeaderCallback) {.exportc.} =
  optimisticHeaderCallback = cb
  echo "optimistic header callback set"

proc setFinalizedHeaderCallback*(cb: OnHeaderCallback) {.exportc.} =
  finalizedHeaderCallback = cb
  echo "finalized header callback set"


proc run(config: VerifiedProxyConf) {.raises: [CatchableError, Exception].} =
  # echo "startLightClient inside nimbus-light-client"

  # Required as both Eth2Node and LightClient requires correct config type
  var lcConfig = config.asLightClientConf()

  setupLogging(config.logLevel, config.logStdout, none(OutFile))

  notice "Launching Nimbus verified proxy",
    version = fullVersionStr, cmdParams = getCLIParams(), config

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

    blockCache = BlockCache.new(uint32(64))

    # TODO: for now we serve all cross origin requests
    authHooks = @[httpCors(@[])]

    clientConfig = config.web3url.asClientConfig()

    rpcProxy = RpcProxy.new(
      [initTAddress(config.rpcAddress, config.rpcPort)],
      clientConfig,
      authHooks
    )

    verifiedProxy = VerifiedRpcProxy.new(rpcProxy, blockCache, chainId)

    optimisticHandler = proc(signedBlock: ForkedMsgTrustedSignedBeaconBlock):
        Future[void] {.async.} =
      notice "New LC optimistic block",
        opt = signedBlock.toBlockId(),
        wallSlot = getBeaconTime().slotOrZero
      withBlck(signedBlock):
        when stateFork >= ConsensusFork.Bellatrix:
          if blck.message.is_execution_block:
            template payload(): auto = blck.message.body.execution_payload
            blockCache.add(asExecutionData(payload.asEngineExecutionPayload()))
        else: discard
      return

    optimisticProcessor = initOptimisticProcessor(
      getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Optimistic)

  verifiedProxy.installEthApiHandlers()

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
  waitFor rpcProxy.start()
  waitFor verifiedProxy.verifyChaindId()

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: ForkedLightClientHeader) =
    withForkyHeader(finalizedHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC finalized header",
          finalized_header = shortLog(forkyHeader)
        if finalizedHeaderCallback != nil:
            notice "### Invoking finalizedHeaderCallback"
            {.gcsafe.}:
              try:
                finalizedHeaderCallback(Json.encode(finalizedHeader))
              except Exception as e:
                notice "finalizedHeaderCallback exception"


  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: ForkedLightClientHeader) =
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC optimistic header",
          optimistic_header = shortLog(forkyHeader)
        optimisticProcessor.setOptimisticHeader(forkyHeader.beacon)
      if optimisticHeaderCallback != nil:
        notice "### Invoking optimisticHeaderCallback"
        {.gcsafe.}:
          try:
            optimisticHeaderCallback(Json.encode(optimisticHeader))
          except Exception:
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
        cfg.CAPELLA_FORK_EPOCH, cfg.DENEB_FORK_EPOCH, isBehind)

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

proc testEcho*() {.exportc.} =
  echo "in testEcho"

proc quit*() {.exportc.} = 
  echo "Quitting"

# template createConfig(clientId: string, ConfType: type, configFilePath: string): untyped =
#   echo "### inside createConfig"
#   let
#     version = clientId & "\p" & copyrights & "\p\p" &
#       "eth2 specification v" & SPEC_VERSION & "\p\p" &
#       nimBanner

#   # TODO for some reason, copyrights are printed when doing `--help`
#   {.push warning[ProveInit]: off.}
#   let config = try:
#     echo "### inside createConfig before load"
#     ConfType.load(
#       version = version, # but a short version string makes more sense...
#       copyrightBanner = clientId,
#       secondarySources = proc (config: ConfType, sources: auto) =
#         sources.addConfigFile(Toml, InputFile(configFilePath))
#     )
#   except CatchableError as err:
#     # We need to log to stderr here, because logging hasn't been configured yet
#     stderr.write "Failure while loading the configuration:\n"
#     stderr.write err.msg
#     stderr.write "\n"

#     if err[] of ConfigurationError and
#        err.parent != nil and
#        err.parent[] of TomlFieldReadingError:
#       let fieldName = ((ref TomlFieldReadingError)(err.parent)).field
#       if fieldName in ["web3-url", "bootstrap-node",
#                        "direct-peer", "validator-monitor-pubkey"]:
#         stderr.write "Since the '" & fieldName & "' option is allowed to " &
#                      "have more than one value, please make sure to supply " &
#                      "a properly formatted TOML array\n"
#     quit 1
#   {.pop.}
#   config

proc NimMain() {.importc.}
proc startProxyViaJson*(configJson: cstring) {.exportc.} =
  echo "startLcViaJson"
  NimMain()
  echo "startLcViaJson 1"
  let str = $configJson
  echo "startLcViaJson 2"
  echo "startLcViaJson 3 ", str
  try:
    let jsonNode = parseJson(str)

    let rpcAddr = jsonNode["RpcAddress"].getStr()
    let config = VerifiedProxyConf(
      rpcAddress: ValidIpAddress.init(rpcAddr), 
      listenAddress: defaultListenAddress, 
      eth2Network: some(jsonNode["Eth2Network"].getStr()), 
      trustedBlockRoot: Eth2Digest.fromHex(jsonNode["TrustedBlockRoot"].getStr()),
      web3Url: parseCmdArg(ValidatedWeb3Url, jsonNode["Web3Url"].getStr()),
      rpcPort: Port(jsonNode["RpcPort"].getInt()),
      logLevel: jsonNode["LogLevel"].getStr(),
      maxPeers: 160,
      nat: NatConfig(hasExtIp: false, nat: NatAny),
      logStdout: StdoutLogKind.Auto,
      dataDir: OutDir(defaultVerifiedProxyDataDir()),
      tcpPort: Port(defaultEth2TcpPort),
      udpPort: Port(defaultEth2TcpPort),
      agentString: "nimbus",
      discv5Enabled: true,
    )

    run(config)
  except Exception as err:
    echo "Exception when running ", getCurrentExceptionMsg(), err.getStackTrace() 

# when isMainModule:
#   let configFileStr = "config.toml"
#   {.pop.}
#   var config = createConfig("Nimbus verified proxy " & fullVersionStr, VerifiedProxyConf, configFileStr)

#   {.push raises: [Defect].}

#   echo "inside nimbus-light-client before run"
#   run(config)

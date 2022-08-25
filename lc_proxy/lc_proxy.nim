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
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/gossip_processing/optimistic_processor,
  beacon_chain/networking/topic_params,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common, version],
  ./rpc/rpc_eth_lc_api

from beacon_chain/consensus_object_pools/consensus_manager import runForkchoiceUpdated
from beacon_chain/gossip_processing/block_processor import newExecutionPayload
from beacon_chain/gossip_processing/eth2_processor import toValidationResult

# TODO Find what can throw exception
proc run() {.raises: [Exception, Defect].}=
  {.pop.}
  var config = makeBannerAndConfig(
    "Nimbus light client " & fullVersionStr, LightClientConf)
  {.push raises: [Defect].}

  setupLogging(config.logLevel, config.logStdout, config.logFile)

  notice "Launching light client",
    version = fullVersionStr, cmdParams = commandLineParams(), config

  let metadata = loadEth2Network(config.eth2Network)
  for node in metadata.bootstrapNodes:
    config.bootstrapNodes.add node
  template cfg(): auto = metadata.cfg

  let
    genesisState =
      try:
        template genesisData(): auto = metadata.genesisData
        newClone(readSszForkedHashedBeaconState(
          cfg, genesisData.toOpenArrayByte(genesisData.low, genesisData.high)))
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    beaconClock = BeaconClock.init(
      getStateField(genesisState[], genesis_time))
    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root =
      getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

    rng = keys.newRng()

    netKeys = getRandomNetKeys(rng[])

    network = createEth2Node(
      rng, config, netKeys, cfg,
      forkDigests, getBeaconTime, genesis_validators_root)

    eth1Mon =
      if config.web3Urls.len > 0:
        let res = Eth1Monitor.init(
          cfg, db = nil, getBeaconTime, config.web3Urls,
          none(DepositContractSnapshot), metadata.eth1Network,
          forcePolling = false,
          rng[].loadJwtSecret(config, allowCreate = false),
          true)
        waitFor res.ensureDataProvider()
        res
      else:
        nil

    rpcServerWithProxy =
      if config.web3Urls.len > 0:
        var web3Url = config.web3Urls[0]
        fixupWeb3Urls web3Url

        let proxyUri = some web3Url

        if proxyUri.isSome:
          info "Initializing LC eth API proxy", proxyUri = proxyUri.get
          let
            ta = initTAddress("127.0.0.1:8545")
            clientConfig =
              case parseUri(proxyUri.get).scheme.toLowerAscii():
              of "http", "https":
                getHttpClientConfig(proxyUri.get)
              of "ws", "wss":
                getWebSocketClientConfig(proxyUri.get)
              else:
                fatal "Unsupported scheme", proxyUri = proxyUri.get
                quit QuitFailure
          RpcProxy.new([ta], clientConfig)
        else:
          warn "Ignoring `rpcEnabled`, no `proxyUri` provided"
          nil
      else:
        nil

    lcProxy =
      if rpcServerWithProxy != nil:
        let res = LightClientRpcProxy(proxy: rpcServerWithProxy)
        res.installEthApiHandlers()
        res
      else:
        nil

    optimisticHandler = proc(signedBlock: ForkedMsgTrustedSignedBeaconBlock):
        Future[void] {.async.} =
      notice "New LC optimistic block",
        opt = signedBlock.toBlockId(),
        wallSlot = getBeaconTime().slotOrZero
      withBlck(signedBlock):
        when stateFork >= BeaconStateFork.Bellatrix:
          if blck.message.is_execution_block:
            template payload(): auto = blck.message.body.execution_payload

            if eth1Mon != nil:
              await eth1Mon.ensureDataProvider()

              # engine_newPayloadV1
              discard await eth1Mon.newExecutionPayload(payload)

              # engine_forkchoiceUpdatedV1
              discard await eth1Mon.runForkchoiceUpdated(
                headBlockRoot = payload.block_hash,
                finalizedBlockRoot = ZERO_HASH)

            if lcProxy != nil:
              lcProxy.executionPayload.ok payload.asEngineExecutionPayload()
        else: discard
      return

    optimisticProcessor = initOptimisticProcessor(
      getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, config, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Optimistic)

  info "Listening to incoming network requests"
  network.initBeaconSync(cfg, forkDigests, genesisBlockRoot, getBeaconTime)
  lightClient.installMessageValidators()
  waitFor network.startListening()
  waitFor network.start()

  if lcProxy != nil:
    waitFor lcProxy.proxy.start()

  proc shouldSyncOptimistically(slot: Slot): bool =
    const
      # Maximum age of light client optimistic header to use optimistic sync
      maxAge = 2 * SLOTS_PER_EPOCH

    if eth1Mon == nil and lcProxy == nil:
      false
    elif getBeaconTime().slotOrZero > slot + maxAge:
      false
    else:
      true

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: BeaconBlockHeader) =
    info "New LC finalized header",
      finalized_header = shortLog(finalizedHeader)
    optimisticProcessor.setFinalizedHeader(finalizedHeader)

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: BeaconBlockHeader) =
    info "New LC optimistic header",
      optimistic_header = shortLog(optimisticHeader)
    optimisticProcessor.setOptimisticHeader(optimisticHeader)

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot

  var nextExchangeTransitionConfTime: Moment

  proc onSecond(time: Moment) =
    # engine_exchangeTransitionConfigurationV1
    if time > nextExchangeTransitionConfTime and eth1Mon != nil:
      nextExchangeTransitionConfTime = time + chronos.minutes(1)
      traceAsyncErrors eth1Mon.exchangeTransitionConfiguration()

    let wallSlot = getBeaconTime().slotOrZero()
    if checkIfShouldStopAtEpoch(wallSlot, config.stopAtEpoch):
      quit(0)

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

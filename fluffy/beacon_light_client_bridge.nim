# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[os, strutils],
  chronicles, chronicles/chronos_tools, chronos,
  eth/keys,
  beacon_chain/eth1/eth1_monitor,
  beacon_chain/gossip_processing/[optimistic_processor, light_client_processor],
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common, version],
  "."/network/beacon_light_client/[
    light_client_db,
    light_client_network,
    light_client_content,
    beacon_light_client_bridge_conf
  ],
  "."/network/wire/[portal_stream, portal_protocol_config, portal_protocol]

# TODO Find what can throw exception
proc run() {.raises: [Exception, Defect].} =
  {.pop.}
  var config = makeBannerAndConfig(
    "Beacon light client bridge " & fullVersionStr, BridgeConf)
  {.push raises: [Defect].}

  # Required as both Eth2Node and LightClient requires correct config type
  var lcConfig = config.asLightClientConf()

  setupLogging(config.logLevel, config.logStdout, none(OutFile))

  notice "Launching Beacon light client bridge",
    version = fullVersionStr, cmdParams = commandLineParams(), config

  let
    metadata = loadEth2Network(lcConfig.eth2Network)

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

    streamManager = StreamManager.new(network.discovery)

    db = LightClientDb.new(lcConfig.dataDir / "db")

    lcNetwork = LightClientNetwork.new(
      network.discovery,
      db,
      streamManager,
      forkDigests[]
    )

    lightClient = createLightClient(
      network, rng, lcConfig, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Optimistic)

  info "Listening to incoming network requests"
  network.initBeaconSync(cfg, forkDigests, genesisBlockRoot, getBeaconTime)

  lightClient.installMessageValidators()
  waitFor network.startListening()
  waitFor network.start()
  lcNetwork.start()

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: BeaconBlockHeader) =
    info "New LC finalized header",
      finalized_header = shortLog(finalizedHeader)

  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: BeaconBlockHeader) =
    info "New LC optimistic header",
      optimistic_header = shortLog(optimisticHeader)

  # TODO Currently the only thing bridge does it to save all lc objects received
  # from libp2p network to portal compatible database format. This way portal
  # nodes can find this content in the network if bridge node is their neighbour.
  # Ultimately bridge node should not only save objects into db, but also actively
  # gossip them into the portal light client network.
  proc onBootstrap(
      lightClient: LightClient,
      bootstrap: altair.LightClientBootstrap) =
    info "New LC boostrap",
      bootstrap, period = bootstrap.header.slot.sync_committee_period

    let
      bh = hash_tree_root(bootstrap.header)
      contentKey = encode(bootstrapContentKey(bh))
      contentId = toContentId(contentKey)
      content = encodeBootstrapForked(
        network.forkDigests.altair,
        bootstrap
      )
    lcNetwork.portalProtocol.storeContent(
      contentKey,
      contentId,
      content
    )

  proc onLCUpdate(lightClient: LightClient, update: altair.LightClientUpdate) =
    info "New LC update",
      update, period = update.attested_header.slot.sync_committee_period
    let
      period = update.attested_header.slot.sync_committee_period
      contentKey = encode(updateContentKey(period.uint64, uint64(1)))
      contentId = toContentId(contentKey)
      content = encodeLightClientUpdatesForked(
        network.forkDigests.altair,
        @[update]
      )
    lcNetwork.portalProtocol.storeContent(
      contentKey,
      contentId,
      content
    )

  proc onOptimisticUpdate(
      lightClient: LightClient,
      optUpdate: altair.LightClientOptimisticUpdate) =
    info "New LC optimistic update",
      optUpdate, period = optUpdate.attested_header.slot.sync_committee_period
    let
      slot = optUpdate.attested_header.slot
      contentKey = encode(optimisticUpdateContentKey(slot.uint64))
      contentId = toContentId(contentKey)
      content = encodeOptimisticUpdateForked(
          network.forkDigests.altair,
          optUpdate
      )
    lcNetwork.portalProtocol.storeContent(
      contentKey,
      contentId,
      content
    )

  proc onFinalityUpdate(
      lightClient: LightClient,
      finUpdate: altair.LightClientFinalityUpdate) =
    info "New LC finality update",
      finUpdate, period = finUpdate.attested_header.slot.sync_committee_period
    let
      finSlot = finUpdate.finalized_header.slot
      optSlot = finUpdate.attested_header.slot
      contentKey = encode(finalityUpdateContentKey(finSlot.uint64, optSlot.uint64))
      contentId = toContentId(contentKey)
      content = encodeFinalityUpdateForked(
          network.forkDigests.altair,
          finUpdate
      )
    lcNetwork.portalProtocol.storeContent(
      contentKey,
      contentId,
      content
    )

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot
  lightClient.bootstrapObserver = onBootstrap
  lightClient.updateObserver = onLCUpdate
  lightClient.finalityUpdateObserver = onFinalityUpdate
  lightClient.optimisticUpdateObserver = onOptimisticUpdate

  proc onSecond(time: Moment) =
    let wallSlot = getBeaconTime().slotOrZero()
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

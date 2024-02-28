# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# The Portal bridge;s task is to inject content into the different Portal networks.
# The bridge acts as a middle man between a content provider (i.e. full node)
# through its exposed API (REST, JSON-RCP, ...), and a Portal node, through the
# Portal JSON-RPC API.
#
# Beacon Network:
#
# For the beacon network a consensus full node is require on one side,
# making use of the Beacon Node REST-API, and a Portal node on the other side,
# making use of the Portal JSON-RPC API.
#
# Portal Network <-> Portal Client (e.g. fluffy) <--JSON-RPC--> bridge <--REST--> consensus client (e.g. Nimbus-eth2)
#
# The Consensus client must support serving the Beacon LC data.
#
# Bootstraps and updates can be backfilled, however how to do this for multiple
# bootstraps is still unsolved.
#
# Updates, optimistic updates and finality updates are injected as they become
# available.
#
# History network:
#
# To be implemented
#
# State network:
#
# To be implemented
#

{.push raises: [].}

import
  std/os,
  chronos,
  confutils,
  confutils/std/net,
  chronicles,
  chronicles/topics_registry,
  json_rpc/clients/httpclient,
  beacon_chain/spec/eth2_apis/rest_beacon_client,
  ../../network/beacon/beacon_content,
  ../../rpc/portal_rpc_client,
  ../../logging,
  ../eth_data_exporter/cl_data_exporter,
  ./portal_bridge_conf,
  ./portal_bridge_beacon

proc runBeacon(config: PortalBridgeConf) {.raises: [CatchableError].} =
  notice "Launching Fluffy beacon chain bridge", cmdParams = commandLineParams()

  let
    (cfg, forkDigests, beaconClock) = getBeaconData()
    getBeaconTime = beaconClock.getBeaconTimeFn()
    portalRpcClient = newRpcHttpClient()
    restClient = RestClientRef.new(config.restUrl).valueOr:
      fatal "Cannot connect to server", error = $error
      quit QuitFailure

  proc backfill(
      beaconRestClient: RestClientRef,
      rpcAddress: string,
      rpcPort: Port,
      backfillAmount: uint64,
      trustedBlockRoot: Option[TrustedDigest],
  ) {.async.} =
    # Bootstrap backfill, currently just one bootstrap selected by
    # trusted-block-root, could become a selected list, or some other way.
    if trustedBlockRoot.isSome():
      await portalRpcClient.connect(rpcAddress, rpcPort, false)

      let res = await gossipLCBootstrapUpdate(
        beaconRestClient, portalRpcClient, trustedBlockRoot.get(), cfg, forkDigests
      )

      if res.isErr():
        warn "Error gossiping LC bootstrap", error = res.error

      await portalRpcClient.close()

    # Updates backfill, selected by backfillAmount
    # Might want to alter this to default backfill to the
    # `MIN_EPOCHS_FOR_BLOCK_REQUESTS`.
    # TODO: This can be up to 128, but our JSON-RPC requests fail with a value
    # higher than 16. TBI
    const updatesPerRequest = 16

    let
      wallSlot = getBeaconTime().slotOrZero()
      currentPeriod = wallSlot div (SLOTS_PER_EPOCH * EPOCHS_PER_SYNC_COMMITTEE_PERIOD)
      requestAmount = backfillAmount div updatesPerRequest
      leftOver = backfillAmount mod updatesPerRequest

    for i in 0 ..< requestAmount:
      await portalRpcClient.connect(rpcAddress, rpcPort, false)

      let res = await gossipLCUpdates(
        beaconRestClient,
        portalRpcClient,
        currentPeriod - updatesPerRequest * (i + 1) + 1,
        updatesPerRequest,
        cfg,
        forkDigests,
      )

      if res.isErr():
        warn "Error gossiping LC updates", error = res.error

      await portalRpcClient.close()

    if leftOver > 0:
      await portalRpcClient.connect(rpcAddress, rpcPort, false)

      let res = await gossipLCUpdates(
        beaconRestClient,
        portalRpcClient,
        currentPeriod - updatesPerRequest * requestAmount - leftOver + 1,
        leftOver,
        cfg,
        forkDigests,
      )

      if res.isErr():
        warn "Error gossiping LC updates", error = res.error

      await portalRpcClient.close()

  var
    lastOptimisticUpdateSlot = Slot(0)
    lastFinalityUpdateEpoch = epoch(lastOptimisticUpdateSlot)
    lastUpdatePeriod = sync_committee_period(lastOptimisticUpdateSlot)

  proc onSlotGossip(wallTime: BeaconTime, lastSlot: Slot) {.async.} =
    let
      wallSlot = wallTime.slotOrZero()
      wallEpoch = epoch(wallSlot)
      wallPeriod = sync_committee_period(wallSlot)

    notice "Slot start info",
      slot = wallSlot,
      epoch = wallEpoch,
      period = wallPeriod,
      lastOptimisticUpdateSlot,
      lastFinalityUpdateEpoch,
      lastUpdatePeriod,
      slotsTillNextEpoch = SLOTS_PER_EPOCH - (wallSlot mod SLOTS_PER_EPOCH),
      slotsTillNextPeriod =
        SLOTS_PER_SYNC_COMMITTEE_PERIOD - (wallSlot mod SLOTS_PER_SYNC_COMMITTEE_PERIOD)

    if wallSlot > lastOptimisticUpdateSlot + 1:
      # TODO: If this turns out to be too tricky to not gossip old updates,
      # then an alternative could be to verify in the gossip calls if the actual
      # slot number received is the correct one, before gossiping into Portal.
      # And/or look into possibly using eth/v1/events for
      # light_client_finality_update and light_client_optimistic_update if that
      # is something that works.

      # Or basically `lightClientOptimisticUpdateSlotOffset`
      await sleepAsync((SECONDS_PER_SLOT div INTERVALS_PER_SLOT).int.seconds)

      await portalRpcClient.connect(config.rpcAddress, Port(config.rpcPort), false)

      let res =
        await gossipLCOptimisticUpdate(restClient, portalRpcClient, cfg, forkDigests)

      if res.isErr():
        warn "Error gossiping LC optimistic update", error = res.error
      else:
        if wallEpoch > lastFinalityUpdateEpoch + 2 and wallSlot > start_slot(wallEpoch):
          let res =
            await gossipLCFinalityUpdate(restClient, portalRpcClient, cfg, forkDigests)

          if res.isErr():
            warn "Error gossiping LC finality update", error = res.error
          else:
            lastFinalityUpdateEpoch = epoch(res.get())

        if wallPeriod > lastUpdatePeriod and wallSlot > start_slot(wallEpoch):
          # TODO: Need to delay timing here also with one slot?
          let res = await gossipLCUpdates(
            restClient,
            portalRpcClient,
            sync_committee_period(wallSlot).uint64,
            1,
            cfg,
            forkDigests,
          )

          if res.isErr():
            warn "Error gossiping LC update", error = res.error
          else:
            lastUpdatePeriod = wallPeriod

        lastOptimisticUpdateSlot = res.get()

  proc runOnSlotLoop() {.async.} =
    var
      curSlot = getBeaconTime().slotOrZero()
      nextSlot = curSlot + 1
      timeToNextSlot = nextSlot.start_beacon_time() - getBeaconTime()
    while true:
      await sleepAsync(timeToNextSlot)

      let
        wallTime = getBeaconTime()
        wallSlot = wallTime.slotOrZero()

      await onSlotGossip(wallTime, curSlot)

      curSlot = wallSlot
      nextSlot = wallSlot + 1
      timeToNextSlot = nextSlot.start_beacon_time() - getBeaconTime()

  waitFor backfill(
    restClient, config.rpcAddress, config.rpcPort, config.backfillAmount,
    config.trustedBlockRoot,
  )

  asyncSpawn runOnSlotLoop()

  while true:
    poll()

when isMainModule:
  {.pop.}
  let config = PortalBridgeConf.load()
  {.push raises: [].}

  setupLogging(config.logLevel, config.logStdout)

  case config.cmd
  of PortalBridgeCmd.beacon:
    runBeacon(config)
  of PortalBridgeCmd.history:
    notice "Functionality not yet implemented"
  of PortalBridgeCmd.state:
    notice "Functionality not yet implemented"

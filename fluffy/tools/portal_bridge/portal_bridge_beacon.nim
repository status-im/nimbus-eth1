# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  chronos,
  chronicles,
  chronicles/topics_registry,
  stew/byteutils,
  eth/async_utils,
  json_rpc/clients/httpclient,
  beacon_chain/spec/eth2_apis/rest_beacon_client,
  ../../network/beacon/beacon_content,
  ../../rpc/portal_rpc_client,
  ../eth_data_exporter/cl_data_exporter,
  ./[portal_bridge_conf, portal_bridge_common]

const
  largeRequestsTimeout = 120.seconds # For downloading large items such as states.
  restRequestsTimeout = 30.seconds

# TODO: From nimbus_binary_common, but we don't want to import that.
proc sleepAsync(t: TimeDiff): Future[void] =
  sleepAsync(nanoseconds(if t.nanoseconds < 0: 0'i64 else: t.nanoseconds))

proc gossipLCBootstrapUpdate(
    restClient: RestClientRef,
    portalRpcClient: RpcClient,
    trustedBlockRoot: Eth2Digest,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
): Future[Result[void, string]] {.async.} =
  var bootstrap =
    try:
      info "Downloading LC bootstrap"
      awaitWithTimeout(
        restClient.getLightClientBootstrap(trustedBlockRoot, cfg, forkDigests),
        restRequestsTimeout,
      ):
        return err("Attempt to download LC bootstrap timed out")
    except CatchableError as exc:
      return err("Unable to download LC bootstrap: " & exc.msg)

  withForkyObject(bootstrap):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.header.beacon.slot
        contentKey = encode(bootstrapContentKey(trustedBlockRoot))
        forkDigest = forkDigestAtEpoch(forkDigests[], epoch(slot), cfg)
        content = encodeBootstrapForked(forkDigest, bootstrap)

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
              contentKeyHex, content.toHex()
            )
          info "Beacon LC bootstrap gossiped", peers, contentKey = contentKeyHex
          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok()
      else:
        return err(res.error)
    else:
      return err("No LC bootstraps pre Altair")

proc gossipLCUpdates(
    restClient: RestClientRef,
    portalRpcClient: RpcClient,
    startPeriod: uint64,
    count: uint64,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
): Future[Result[void, string]] {.async.} =
  var updates =
    try:
      info "Downloading LC updates", count
      awaitWithTimeout(
        restClient.getLightClientUpdatesByRange(
          SyncCommitteePeriod(startPeriod), count, cfg, forkDigests
        ),
        restRequestsTimeout,
      ):
        return err("Attempt to download LC updates timed out")
    except CatchableError as exc:
      return err("Unable to download LC updates: " & exc.msg)

  if updates.len() > 0:
    withForkyObject(updates[0]):
      when lcDataFork > LightClientDataFork.None:
        let
          slot = forkyObject.attested_header.beacon.slot
          period = slot.sync_committee_period
          contentKey = encode(updateContentKey(period.uint64, count))
          forkDigest = forkDigestAtEpoch(forkDigests[], epoch(slot), cfg)

          content = encodeLightClientUpdatesForked(forkDigest, updates)

        proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex, content.toHex()
              )
            info "Beacon LC update gossiped",
              peers, contentKey = contentKeyHex, period, count
            return ok()
          except CatchableError as e:
            return err("JSON-RPC error: " & $e.msg)

        let res = await GossipRpcAndClose()
        if res.isOk():
          return ok()
        else:
          return err(res.error)
      else:
        return err("No LC updates pre Altair")
  else:
    # TODO:
    # currently only error if no updates at all found. This might be due
    # to selecting future period or too old period.
    # Might want to error here in case count != updates.len or might not want to
    # error at all and perhaps return the updates.len.
    return err("No updates downloaded")

proc gossipLCFinalityUpdate(
    restClient: RestClientRef,
    portalRpcClient: RpcClient,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
): Future[Result[(Slot, Eth2Digest), string]] {.async.} =
  var update =
    try:
      info "Downloading LC finality update"
      awaitWithTimeout(
        restClient.getLightClientFinalityUpdate(cfg, forkDigests), restRequestsTimeout
      ):
        return err("Attempt to download LC finality update timed out")
    except CatchableError as exc:
      return err("Unable to download LC finality update: " & exc.msg)

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        finalizedSlot = forkyObject.finalized_header.beacon.slot
        blockRoot = hash_tree_root(forkyObject.finalized_header.beacon)
        contentKey = encode(finalityUpdateContentKey(finalizedSlot.uint64))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg
        )
        content = encodeFinalityUpdateForked(forkDigest, update)

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
              contentKeyHex, content.toHex()
            )
          info "Beacon LC finality update gossiped",
            peers, contentKey = contentKeyHex, finalizedSlot
          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok((finalizedSlot, blockRoot))
      else:
        return err(res.error)
    else:
      return err("No LC updates pre Altair")

proc gossipLCOptimisticUpdate(
    restClient: RestClientRef,
    portalRpcClient: RpcClient,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
): Future[Result[Slot, string]] {.async.} =
  var update =
    try:
      info "Downloading LC optimistic update"
      awaitWithTimeout(
        restClient.getLightClientOptimisticUpdate(cfg, forkDigests), restRequestsTimeout
      ):
        return err("Attempt to download LC optimistic update timed out")
    except CatchableError as exc:
      return err("Unable to download LC optimistic update: " & exc.msg)

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.signature_slot
        contentKey = encode(optimisticUpdateContentKey(slot.uint64))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg
        )
        content = encodeOptimisticUpdateForked(forkDigest, update)

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
              contentKeyHex, content.toHex()
            )
          info "Beacon LC optimistic update gossiped",
            peers, contentKey = contentKeyHex, slot

          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok(slot)
      else:
        return err(res.error)
    else:
      return err("No LC updates pre Altair")

proc gossipHistoricalSummaries(
    restClient: RestClientRef,
    portalRpcClient: RpcClient,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
): Future[Result[void, string]] {.async.} =
  let state =
    try:
      notice "Downloading beacon state"
      awaitWithTimeout(
        restClient.getStateV2(StateIdent.init(StateIdentType.Finalized), cfg),
        largeRequestsTimeout,
      ):
        return err("Attempt to download beacon state timed out")
    except CatchableError as exc:
      return err("Unable to download beacon state: " & exc.msg)

  if state == nil:
    return err("No beacon state found")

  withState(state[]):
    when consensusFork >= ConsensusFork.Capella:
      let
        historical_summaries = forkyState.data.historical_summaries
        proof = ?buildProof(state[])
        epoch = forkyState.data.slot.epoch()
        forkDigest = forkDigestAtEpoch(forkDigests[], epoch, cfg)
        summariesWithProof = HistoricalSummariesWithProof(
          epoch: epoch, historical_summaries: historical_summaries, proof: proof
        )

        contentKey = encode(historicalSummariesContentKey(epoch.uint64))
        content = encodeSsz(summariesWithProof, forkDigest)

      try:
        let peers = await portalRpcClient.portal_beaconRandomGossip(
          contentKey.asSeq().toHex(), content.toHex()
        )
        info "Beacon historical_summaries gossiped", peers, epoch

        return ok()
      except CatchableError as e:
        return err("JSON-RPC error: " & $e.msg)
    else:
      return err("No historical_summaries pre Capella")

proc runBeacon*(config: PortalBridgeConf) {.raises: [CatchableError].} =
  notice "Launching Fluffy beacon chain bridge", cmdParams = commandLineParams()

  let
    (cfg, forkDigests, beaconClock) = getBeaconData()
    getBeaconTime = beaconClock.getBeaconTimeFn()
    portalRpcClient = newRpcClientConnect(config.portalRpcUrl)
    restClient = RestClientRef.new(config.restUrl).valueOr:
      fatal "Cannot connect to server", error = $error
      quit QuitFailure

  proc backfill(
      beaconRestClient: RestClientRef,
      portalRpcClient: RpcClient,
      backfillAmount: uint64,
      trustedBlockRoot: Option[TrustedDigest],
  ) {.async.} =
    # TODO:
    # It can get tricky when we need to bootstrap the beacon network with
    # a portal_bridge:
    # - Either a very recent bootstrap needs to be taken so that no updates are
    # required for the nodes to sync.
    # - Or the bridge needs to be tuned together with the selected bootstrap to
    # provide the right amount of backfill updates.
    # - Or the above point could get automatically implemented here based on the
    # provided trusted-block-root

    # Bootstrap backfill, currently just one bootstrap selected by
    # trusted-block-root, could become a selected list, or some other way.
    if trustedBlockRoot.isSome():
      let res = await gossipLCBootstrapUpdate(
        beaconRestClient, portalRpcClient, trustedBlockRoot.get(), cfg, forkDigests
      )

      if res.isErr():
        warn "Error gossiping LC bootstrap", error = res.error

      await portalRpcClient.close()

    # Add some seconds delay to allow the bootstrap to be gossiped around.
    # Without the bootstrap, following updates will not get accepted.
    await sleepAsync(5.seconds)

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
            let (slot, blockRoot) = res.value()
            lastFinalityUpdateEpoch = epoch(slot)
            let res = await gossipLCBootstrapUpdate(
              restClient, portalRpcClient, blockRoot, cfg, forkDigests
            )

            if res.isErr():
              warn "Error gossiping LC bootstrap", error = res.error

          let res2 = await gossipHistoricalSummaries(
            restClient, portalRpcClient, cfg, forkDigests
          )
          if res2.isErr():
            warn "Error gossiping historical summaries", error = res.error

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
    restClient, portalRpcClient, config.backfillAmount, config.trustedBlockRoot
  )

  asyncSpawn runOnSlotLoop()

  while true:
    poll()

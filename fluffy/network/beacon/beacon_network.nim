# fluffy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  eth/p2p/discoveryv5/[protocol, enr],
  beacon_chain/spec/forks,
  beacon_chain/gossip_processing/light_client_processor,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config, ping_extensions],
  "."/[beacon_content, beacon_db, beacon_validation, beacon_chain_historical_summaries]

export beacon_content, beacon_db

logScope:
  topics = "portal_beacon"

const pingExtensionCapabilities = {CapabilitiesType, BasicRadiusType}

type BeaconNetwork* = ref object
  portalProtocol*: PortalProtocol
  beaconDb*: BeaconDb
  processor*: ref LightClientProcessor
  contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
  forkDigests*: ForkDigests
  getBeaconTime: GetBeaconTimeFn
  cfg*: RuntimeConfig
  trustedBlockRoot*: Opt[Eth2Digest]
  processContentLoop: Future[void]
  statusLogLoop: Future[void]
  onEpochLoop: Future[void]
  onPeriodLoop: Future[void]

func toContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

proc validateHistoricalSummaries(
    n: BeaconNetwork, summariesWithProof: HistoricalSummariesWithProof
): Result[void, string] =
  let
    finalityUpdate = getLastFinalityUpdate(n.beaconDb).valueOr:
      return err("Require finality update for verification")

    # TODO: compare slots first
    stateRoot = withForkyFinalityUpdate(finalityUpdate):
      when lcDataFork > LightClientDataFork.None:
        forkyFinalityUpdate.finalized_header.beacon.state_root
      else:
        # Note: this should always be the case as historical_summaries was
        # introduced in Capella.
        return err("Require Altair or > for verification")

  if summariesWithProof.verifyProof(stateRoot):
    ok()
  else:
    err("Failed verifying historical_summaries proof")

proc getContent(
    n: BeaconNetwork, contentKey: ContentKey
): Future[results.Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
  let
    contentKeyEncoded = encode(contentKey)
    contentId = toContentId(contentKeyEncoded)
    localContent = n.portalProtocol.dbGet(contentKeyEncoded, contentId)

  if localContent.isSome():
    return localContent

  let contentRes = await n.portalProtocol.contentLookup(contentKeyEncoded, contentId)

  if contentRes.isNone():
    warn "Failed fetching content from the beacon chain network",
      contentKey = contentKeyEncoded
    Opt.none(seq[byte])
  else:
    Opt.some(contentRes.value().content)

proc getLightClientBootstrap*(
    n: BeaconNetwork, trustedRoot: Digest
): Future[results.Opt[ForkedLightClientBootstrap]] {.async: (raises: [CancelledError]).} =
  let
    contentKey = bootstrapContentKey(trustedRoot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientBootstrap)

  let
    bootstrap = contentResult.value()
    decodingResult = decodeLightClientBootstrapForked(n.forkDigests, bootstrap)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientBootstrap)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.value())

proc getLightClientUpdatesByRange*(
    n: BeaconNetwork, startPeriod: SyncCommitteePeriod, count: uint64
): Future[results.Opt[ForkedLightClientUpdateList]] {.
    async: (raises: [CancelledError])
.} =
  let
    contentKey = updateContentKey(distinctBase(startPeriod), count)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientUpdateList)

  let
    updates = contentResult.value()
    decodingResult = decodeLightClientUpdatesByRange(n.forkDigests, updates)

  if decodingResult.isErr():
    Opt.none(ForkedLightClientUpdateList)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    Opt.some(decodingResult.value())

proc getLightClientFinalityUpdate*(
    n: BeaconNetwork, finalizedSlot: uint64
): Future[results.Opt[ForkedLightClientFinalityUpdate]] {.
    async: (raises: [CancelledError])
.} =
  let
    contentKey = finalityUpdateContentKey(finalizedSlot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientFinalityUpdate)

  let
    finalityUpdate = contentResult.value()
    decodingResult =
      decodeLightClientFinalityUpdateForked(n.forkDigests, finalityUpdate)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientFinalityUpdate)
  else:
    return Opt.some(decodingResult.value())

proc getLightClientOptimisticUpdate*(
    n: BeaconNetwork, optimisticSlot: uint64
): Future[results.Opt[ForkedLightClientOptimisticUpdate]] {.
    async: (raises: [CancelledError])
.} =
  let
    contentKey = optimisticUpdateContentKey(optimisticSlot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientOptimisticUpdate)

  let
    optimisticUpdate = contentResult.value()
    decodingResult =
      decodeLightClientOptimisticUpdateForked(n.forkDigests, optimisticUpdate)

  if decodingResult.isErr():
    Opt.none(ForkedLightClientOptimisticUpdate)
  else:
    Opt.some(decodingResult.value())

proc getHistoricalSummaries*(
    n: BeaconNetwork, epoch: uint64
): Future[results.Opt[HistoricalSummaries]] {.async: (raises: [CancelledError]).} =
  # Note: when taken from the db, it does not need to verify the proof.
  let
    contentKey = historicalSummariesContentKey(epoch)
    content = ?await n.getContent(contentKey)

    summariesWithProof = decodeSsz(n.forkDigests, content, HistoricalSummariesWithProof).valueOr:
      return Opt.none(HistoricalSummaries)

  if n.validateHistoricalSummaries(summariesWithProof).isOk():
    Opt.some(summariesWithProof.historical_summaries)
  else:
    Opt.none(HistoricalSummaries)

proc new*(
    T: type BeaconNetwork,
    portalNetwork: PortalNetwork,
    baseProtocol: protocol.Protocol,
    beaconDb: BeaconDb,
    streamManager: StreamManager,
    forkDigests: ForkDigests,
    getBeaconTime: GetBeaconTimeFn,
    cfg: RuntimeConfig,
    trustedBlockRoot: Opt[Eth2Digest],
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
): T =
  let
    contentQueue = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

    stream = streamManager.registerNewStream(contentQueue)

    portalProtocol = PortalProtocol.new(
      baseProtocol,
      getProtocolId(portalNetwork, PortalSubnetwork.beacon),
      toContentIdHandler,
      createGetHandler(beaconDb),
      createStoreHandler(beaconDb),
      createContainsHandler(beaconDb),
      createRadiusHandler(beaconDb),
      stream,
      bootstrapRecords,
      config = portalConfig,
      pingExtensionCapabilities = pingExtensionCapabilities,
    )

  let beaconBlockRoot =
    # TODO: Need to have some form of weak subjectivity check here.
    if trustedBlockRoot.isNone():
      beaconDb.getLatestBlockRoot()
    else:
      trustedBlockRoot

  BeaconNetwork(
    portalProtocol: portalProtocol,
    beaconDb: beaconDb,
    contentQueue: contentQueue,
    forkDigests: forkDigests,
    getBeaconTime: getBeaconTime,
    cfg: cfg,
    trustedBlockRoot: beaconBlockRoot,
  )

proc lightClientVerifier(
    processor: ref LightClientProcessor, obj: SomeForkedLightClientObject
): Future[Result[void, VerifierError]] {.async: (raises: [CancelledError], raw: true).} =
  let resfut = Future[Result[void, VerifierError]].Raising([CancelledError]).init(
      "lightClientVerifier"
    )
  processor[].addObject(MsgSource.gossip, obj, resfut)
  resfut

proc updateVerifier*(
    processor: ref LightClientProcessor, obj: ForkedLightClientUpdate
): auto =
  processor.lightClientVerifier(obj)

proc validateContent(
    n: BeaconNetwork, content: seq[byte], contentKey: ContentKeyByteList
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let key = contentKey.decode().valueOr:
    return err("Error decoding content key")

  case key.contentType
  of unused:
    raiseAssert "Should not be used and fail at decoding"
  of lightClientBootstrap:
    let bootstrap = decodeLightClientBootstrapForked(n.forkDigests, content).valueOr:
      return err("Error decoding bootstrap: " & error)

    withForkyBootstrap(bootstrap):
      when lcDataFork > LightClientDataFork.None:
        # Try getting last finality update from db. If the node is LC synced
        # this data should be there. Then check is done to see if the headers
        # are the same.
        # Note that this will only work for newly created LC bootstraps. If
        # backfill of bootstraps is to be supported, they need to be provided
        # with a proof against historical summaries.
        # See also:
        # https://github.com/ethereum/portal-network-specs/issues/296
        let finalityUpdate = n.beaconDb.getLastFinalityUpdate()
        if finalityUpdate.isOk():
          withForkyFinalityUpdate(finalityUpdate.value):
            when lcDataFork > LightClientDataFork.None:
              if forkyFinalityUpdate.finalized_header.beacon !=
                  forkyBootstrap.header.beacon:
                return err("Bootstrap header does not match recent finalized header")

              if forkyBootstrap.isValidBootstrap(n.beaconDb.cfg):
                ok()
              else:
                err("Error validating LC bootstrap")
            else:
              err("No LC data before Altair")
        elif n.trustedBlockRoot.isSome():
          # If not yet synced, try trusted block root
          let blockRoot = hash_tree_root(forkyBootstrap.header.beacon)
          if blockRoot != n.trustedBlockRoot.get():
            return err("Bootstrap header does not match trusted block root")

          if forkyBootstrap.isValidBootstrap(n.beaconDb.cfg):
            ok()
          else:
            err("Error validating LC bootstrap")
        else:
          err("Cannot validate LC bootstrap")
      else:
        err("No LC data before Altair")
  of lightClientUpdate:
    let updates = decodeLightClientUpdatesByRange(n.forkDigests, content).valueOr:
      return err("Error decoding content: " & error)

    # Only new updates can be verified as they get applied by the LC processor,
    # so verification works only by being part of the sync process.
    # This means that no backfill is possible, for that we need updates that
    # get provided with a proof against historical_summaries, see also:
    # https://github.com/ethereum/portal-network-specs/issues/305
    # It is however a little more tricky, even updates that we do not have
    # applied yet may fail here if the list of updates does not contain first
    # the next update that is required currently for the sync.
    for update in updates:
      let res = await n.processor.updateVerifier(update)
      if res.isErr():
        return err("Error verifying LC updates: " & $res.error)

    ok()
  of lightClientFinalityUpdate:
    let update = decodeLightClientFinalityUpdateForked(n.forkDigests, content).valueOr:
      return err("Error decoding content: " & error)

    let res = n.processor[].processLightClientFinalityUpdate(MsgSource.gossip, update)
    if res.isErr():
      err("Error processing update: " & $res.error[1])
    else:
      ok()
  of lightClientOptimisticUpdate:
    let update = decodeLightClientOptimisticUpdateForked(n.forkDigests, content).valueOr:
      return err("Error decoding content: " & error)

    let res = n.processor[].processLightClientOptimisticUpdate(MsgSource.gossip, update)
    if res.isErr():
      err("Error processing update: " & $res.error[1])
    else:
      ok()
  of beacon_content.ContentType.historicalSummaries:
    let summariesWithProof =
      ?decodeSsz(n.forkDigests, content, HistoricalSummariesWithProof)

    n.validateHistoricalSummaries(summariesWithProof)

proc validateContent(
    n: BeaconNetwork,
    srcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    contentItems: seq[seq[byte]],
): Future[bool] {.async: (raises: [CancelledError]).} =
  # content passed here can have less items then contentKeys, but not more.
  for i, contentItem in contentItems:
    let
      contentKey = contentKeys[i]
      validation = await n.validateContent(contentItem, contentKey)
    if validation.isOk():
      let contentIdOpt = n.portalProtocol.toContentId(contentKey)
      if contentIdOpt.isNone():
        error "Received offered content with invalid content key", srcNodeId, contentKey
        return false

      let contentId = contentIdOpt.get()
      n.portalProtocol.storeContent(contentKey, contentId, contentItem)

      debug "Received offered content validated successfully", srcNodeId, contentKey
    else:
      debug "Received offered content failed validation",
        srcNodeId, contentKey, error = validation.error
      return false

  return true

proc sleepAsync(
    t: TimeDiff
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  sleepAsync(nanoseconds(if t.nanoseconds < 0: 0'i64 else: t.nanoseconds))

proc onEpoch(n: BeaconNetwork, wallTime: BeaconTime, wallEpoch: Epoch) =
  debug "Epoch transition", epoch = shortLog(wallEpoch)

  n.beaconDb.keepBootstrapsFrom(
    Slot((wallEpoch - n.cfg.MIN_EPOCHS_FOR_BLOCK_REQUESTS) * SLOTS_PER_EPOCH)
  )

proc onPeriod(n: BeaconNetwork, wallTime: BeaconTime, wallPeriod: SyncCommitteePeriod) =
  debug "Period transition", period = shortLog(wallPeriod)

  n.beaconDb.keepUpdatesFrom(wallPeriod - n.cfg.defaultLightClientDataMaxPeriods())

proc onEpochLoop(n: BeaconNetwork) {.async: (raises: []).} =
  try:
    var
      currentEpoch = n.getBeaconTime().slotOrZero().epoch()
      nextEpoch = currentEpoch + 1
      timeToNextEpoch = nextEpoch.start_slot().start_beacon_time() - n.getBeaconTime()
    while true:
      await sleepAsync(timeToNextEpoch)

      let
        wallTime = n.getBeaconTime()
        wallEpoch = wallTime.slotOrZero().epoch()

      n.onEpoch(wallTime, wallEpoch)

      currentEpoch = wallEpoch
      nextEpoch = currentEpoch + 1
      timeToNextEpoch = nextEpoch.start_slot().start_beacon_time() - n.getBeaconTime()
  except CancelledError:
    trace "onEpochLoop canceled"

proc onPeriodLoop(n: BeaconNetwork) {.async: (raises: []).} =
  try:
    var
      currentPeriod = n.getBeaconTime().slotOrZero().sync_committee_period()
      nextPeriod = currentPeriod + 1
      timeToNextPeriod = nextPeriod.start_slot().start_beacon_time() - n.getBeaconTime()
    while true:
      await sleepAsync(timeToNextPeriod)

      let
        wallTime = n.getBeaconTime()
        wallPeriod = wallTime.slotOrZero().sync_committee_period()

      n.onPeriod(wallTime, wallPeriod)

      currentPeriod = wallPeriod
      nextPeriod = currentPeriod + 1
      timeToNextPeriod = nextPeriod.start_slot().start_beacon_time() - n.getBeaconTime()
  except CancelledError:
    trace "onPeriodLoop canceled"

proc processContentLoop(n: BeaconNetwork) {.async: (raises: []).} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentItems) = await n.contentQueue.popFirst()

      # When there is one invalid content item, all other content items are
      # dropped and not gossiped around.
      # TODO: Differentiate between failures due to invalid data and failures
      # due to missing network data for validation.
      if await n.validateContent(srcNodeId, contentKeys, contentItems):
        asyncSpawn n.portalProtocol.randomGossipDiscardPeers(
          srcNodeId, contentKeys, contentItems
        )
  except CancelledError:
    trace "processContentLoop canceled"

proc statusLogLoop(n: BeaconNetwork) {.async: (raises: []).} =
  try:
    while true:
      info "Beacon network status",
        routingTableNodes = n.portalProtocol.routingTable.len()

      await sleepAsync(60.seconds)
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: BeaconNetwork) =
  info "Starting Portal beacon chain network"

  n.portalProtocol.start()
  n.processContentLoop = processContentLoop(n)
  n.statusLogLoop = statusLogLoop(n)
  n.onEpochLoop = onEpochLoop(n)
  n.onPeriodLoop = onPeriodLoop(n)

proc stop*(n: BeaconNetwork) {.async: (raises: []).} =
  info "Stopping Portal beacon chain network"

  var futures: seq[Future[void]]
  futures.add(n.portalProtocol.stop())

  if not n.processContentLoop.isNil():
    futures.add(n.processContentLoop.cancelAndWait())

  if not n.statusLogLoop.isNil():
    futures.add(n.statusLogLoop.cancelAndWait())

  if not n.onEpochLoop.isNil():
    futures.add(n.onEpochLoop.cancelAndWait())

  if not n.onPeriodLoop.isNil():
    futures.add(n.onPeriodLoop.cancelAndWait())

  await noCancel(allFutures(futures))

  n.beaconDb.close()

  n.processContentLoop = nil
  n.statusLogLoop = nil

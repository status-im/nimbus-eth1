# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import chronos, chronicles
import
  beacon_chain/beacon_clock,
  beacon_chain/networking/peer_scores,
  beacon_chain/[light_client_sync_helpers, sync_manager]

logScope:
  topics = "lcman"

type
  Nothing = object
  ResponseError = object of CatchableError
  Endpoint[K, V] =
    (K, V) # https://github.com/nim-lang/Nim/issues/19531
  Bootstrap =
    Endpoint[Eth2Digest, ForkedLightClientBootstrap]
  UpdatesByRange =
    Endpoint[
      tuple[startPeriod: SyncCommitteePeriod, count: uint64],
      ForkedLightClientUpdate]
  FinalityUpdate =
    Endpoint[Nothing, ForkedLightClientFinalityUpdate]
  OptimisticUpdate =
    Endpoint[Nothing, ForkedLightClientOptimisticUpdate]

  ValueVerifier[V] =
    proc(v: V): Future[Result[void, LightClientVerifierError]] {.async: (raises: [CancelledError]).}
  BootstrapVerifier* =
    ValueVerifier[ForkedLightClientBootstrap]
  UpdateVerifier* =
    ValueVerifier[ForkedLightClientUpdate]
  FinalityUpdateVerifier* =
    ValueVerifier[ForkedLightClientFinalityUpdate]
  OptimisticUpdateVerifier* =
    ValueVerifier[ForkedLightClientOptimisticUpdate]

  GetTrustedBlockRootCallback* =
    proc(): Option[Eth2Digest] {.gcsafe, raises: [].}
  GetBoolCallback* =
    proc(): bool {.gcsafe, raises: [].}
  GetSyncCommitteePeriodCallback* =
    proc(): SyncCommitteePeriod {.gcsafe, raises: [].}

  LightClientBootstrapProc = proc(id: uint64, blockRoot: Eth2Digest): Future[NetRes[ForkedLightClientBootstrap]]
  LightClientUpdatesByRangeProc = proc(id: uint64, startPeriod: SyncCommitteePeriod, count: uint64): Future[NetRes[ForkedLightClientUpdateList]]
  LightClientFinalityUpdateProc = proc(id: uint64): Future[NetRes[ForkedLightClientFinalityUpdate]]
  LightClientOptimisticUpdateProc = proc(id: uint64): Future[NetRes[ForkedLightClientOptimisticUpdate]]
  ReportResponseQualityProc = proc(id: uint64, value: int)

  EthLCBackend* = object
    getLightClientBootstrap: LightClientBootstrapProc
    getLightClientUpdatesByRange: LightClientUpdatesByRangeProc
    getLightClientFinalityUpdate: LightClientFInalityUpdateProc
    getLightClientOptimisticUpdate: LightClientOptimisticUpdateProc
    reportRequestQuality: ReportRequestQualityProc

  LightClientManager* = object
    rng: ref HmacDrbgContext
    backend*: EthLCBackend
    getTrustedBlockRoot: GetTrustedBlockRootCallback
    bootstrapVerifier: BootstrapVerifier
    updateVerifier: UpdateVerifier
    finalityUpdateVerifier: FinalityUpdateVerifier
    optimisticUpdateVerifier: OptimisticUpdateVerifier
    isLightClientStoreInitialized: GetBoolCallback
    isNextSyncCommitteeKnown: GetBoolCallback
    getFinalizedPeriod: GetSyncCommitteePeriodCallback
    getOptimisticPeriod: GetSyncCommitteePeriodCallback
    getBeaconTime: GetBeaconTimeFn
    loopFuture: Future[void].Raising([CancelledError])

func init*(
    T: type LightClientManager,
    rng: ref HmacDrbgContext,
    getTrustedBlockRoot: GetTrustedBlockRootCallback,
    bootstrapVerifier: BootstrapVerifier,
    updateVerifier: UpdateVerifier,
    finalityUpdateVerifier: FinalityUpdateVerifier,
    optimisticUpdateVerifier: OptimisticUpdateVerifier,
    isLightClientStoreInitialized: GetBoolCallback,
    isNextSyncCommitteeKnown: GetBoolCallback,
    getFinalizedPeriod: GetSyncCommitteePeriodCallback,
    getOptimisticPeriod: GetSyncCommitteePeriodCallback,
    getBeaconTime: GetBeaconTimeFn,
): LightClientManager =
  ## Initialize light client manager.
  LightClientManager(
    rng: rng,
    getTrustedBlockRoot: getTrustedBlockRoot,
    bootstrapVerifier: bootstrapVerifier,
    updateVerifier: updateVerifier,
    finalityUpdateVerifier: finalityUpdateVerifier,
    optimisticUpdateVerifier: optimisticUpdateVerifier,
    isLightClientStoreInitialized: isLightClientStoreInitialized,
    isNextSyncCommitteeKnown: isNextSyncCommitteeKnown,
    getFinalizedPeriod: getFinalizedPeriod,
    getOptimisticPeriod: getOptimisticPeriod,
    getBeaconTime: getBeaconTime)

# https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.3/specs/altair/light-client/p2p-interface.md#getlightclientbootstrap
proc doRequest(
    e: typedesc[Bootstrap],
    backend: EthLCBackend,
    reqId: uint64, 
    blockRoot: Eth2Digest
): Future[NetRes[ForkedLightClientBootstrap]] {.async: (raises: [CancelledError], raw: true).} =
  backend.getLightClientBootstrap(reqId, blockRoot)

# https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.3/specs/altair/light-client/p2p-interface.md#lightclientupdatesbyrange
type LightClientUpdatesByRangeResponse =
  NetRes[List[ForkedLightClientUpdate, MAX_REQUEST_LIGHT_CLIENT_UPDATES]]
proc doRequest(
    e: typedesc[UpdatesByRange],
    backend: EthLCBackend,
    reqId: uint64, 
    key: tuple[startPeriod: SyncCommitteePeriod, count: uint64]
): Future[LightClientUpdatesByRangeResponse] {.async: (raises: [ResponseError, CancelledError]).} =
  let (startPeriod, count) = key
  doAssert count > 0 and count <= MAX_REQUEST_LIGHT_CLIENT_UPDATES
  let response = await backend.getLightClientUpdatesByRange(reqId, startPeriod, count)
  if response.isOk:
    let e = distinctBase(response.get)
      .checkLightClientUpdates(startPeriod, count)
    if e.isErr:
      raise newException(ResponseError, e.error)
  return response

# https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.3/specs/altair/light-client/p2p-interface.md#getlightclientfinalityupdate
proc doRequest(
    e: typedesc[FinalityUpdate],
    backend: EthLCBackend,
    reqId: uint64
): Future[NetRes[ForkedLightClientFinalityUpdate]] {.async: (raises: [CancelledError], raw: true).} =
  backend.getLightClientFinalityUpdate(reqId)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/altair/light-client/p2p-interface.md#getlightclientoptimisticupdate
proc doRequest(
    e: typedesc[OptimisticUpdate],
    backend: EthLCBackend,
    reqId: uint64
): Future[NetRes[ForkedLightClientOptimisticUpdate]] {.async: (raises: [CancelledError], raw: true).} =
  backend.getLightClientOptimisticUpdate(reqId)

template valueVerifier[E](
    self: LightClientManager,
    e: typedesc[E]
): ValueVerifier[E.V] =
  when E.V is ForkedLightClientBootstrap:
    self.bootstrapVerifier
  elif E.V is ForkedLightClientUpdate:
    self.updateVerifier
  elif E.V is ForkedLightClientFinalityUpdate:
    self.finalityUpdateVerifier
  elif E.V is ForkedLightClientOptimisticUpdate:
    self.optimisticUpdateVerifier
  else: static: doAssert false

iterator values(v: auto): auto =
  ## Local helper for `workerTask` to share the same implementation for both
  ## scalar and aggregate values, by treating scalars as 1-length aggregates.
  when v is List:
    for i in v:
      yield i
  else:
    yield v

proc workerTask[E](
    self: LightClientManager,
    e: typedesc[E],
    key: E.K
): Future[bool] {.async: (raises: [CancelledError]).} =
  var
    didProgress = false
  try:
    var reqId: uint64
    self.rng[].generate(reqId)

    let value =
      when E.K is Nothing:
        await E.doRequest(self.backend, reqId)
      else:
        await E.doRequest(self.backend, reqId, key)
    if value.isOk:
      var applyReward = false
      for val in value.get().values:
        let res = await self.valueVerifier(E)(val)
        if res.isErr:
          case res.error
          of LightClientVerifierError.MissingParent:
            # Stop, requires different request to progress
            return didProgress
          of LightClientVerifierError.Duplicate:
            # Ignore, a concurrent request may have already fulfilled this
            when E.V is ForkedLightClientBootstrap:
              didProgress = true
            else:
              discard
          of LightClientVerifierError.UnviableFork:
            # Descore, peer is on an incompatible fork version
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                notice "Received value from an unviable fork", value = forkyObject, endpoint = E.name
              else:
                notice "Received value from an unviable fork", endpoint = E.name
            self.backend.reportRequestQuality(reqId, PeerScoreUnviableFork)
            return didProgress
          of LightClientVerifierError.Invalid:
            # Descore, received data is malformed
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                warn "Received invalid value", value = forkyObject.shortLog, endpoint = E.name
              else:
                warn "Received invalid value", endpoint = E.name
            self.backend.reportRequestQuality(reqId, PeerScoreBadValues)
            return didProgress
        else:
          # Reward, peer returned something useful
          applyReward = true
          didProgress = true
      if applyReward:
        self.backend.reportRequestQuality(reqId, PeerScoreGoodValues)
    else:
      self.backend.reportRequestQuality(reqId, PeerScoreNoValues)
      debug "Failed to receive value on request", value, endpoint = E.name
  except ResponseError as exc:
    warn "Received invalid response", error = exc.msg, endpoint = E.name
    self.backend.reportRequestQuality(reqId, PeerScoreBadValues)
  except CancelledError as exc:
    raise exc

  return didProgress

proc query[E](
    self: LightClientManager,
    e: typedesc[E],
    key: E.K
): Future[bool] {.async: (raises: [CancelledError]).} =
  const PARALLEL_REQUESTS = 2
  var workers: array[PARALLEL_REQUESTS, Future[bool]]

  let
    progressFut = Future[void].Raising([CancelledError]).init("lcmanProgress")
    doneFut = Future[void].Raising([CancelledError]).init("lcmanDone")
  var
    numCompleted = 0
    maxCompleted = workers.len

  proc handleFinishedWorker(future: pointer) =
    try:
      let didProgress = cast[Future[bool]](future).read()
      if didProgress and not progressFut.finished:
        progressFut.complete()
    except CancelledError:
      if not progressFut.finished:
        progressFut.cancelSoon()
    except CatchableError:
      discard
    finally:
      inc numCompleted
      if numCompleted == maxCompleted:
        doneFut.complete()

  try:
    # Start concurrent workers
    for i in 0 ..< workers.len:
      try:
        workers[i] = self.workerTask(e, key)
        workers[i].addCallback(handleFinishedWorker)
      except CancelledError as exc:
        raise exc
      except CatchableError:
        workers[i] = newFuture[bool]()
        workers[i].complete(false)

    # Wait for any worker to report progress, or for all workers to finish
    try:
      discard await race(progressFut, doneFut)
    except ValueError:
      raiseAssert "race API invariant"
  finally:
    for i in 0 ..< maxCompleted:
      if workers[i] == nil:
        maxCompleted = i
        if numCompleted == maxCompleted:
          doneFut.complete()
        break
      if not workers[i].finished:
        workers[i].cancelSoon()
    while true:
      try:
        await allFutures(workers[0 ..< maxCompleted])
        break
      except CancelledError:
        continue
    while true:
      try:
        await doneFut
        break
      except CancelledError:
        continue

  if not progressFut.finished:
    progressFut.cancelSoon()
  return progressFut.completed

template query[E](
    self: LightClientManager,
    e: typedesc[E]
): Future[bool].Raising([CancelledError]) =
  self.query(e, Nothing())

# https://github.com/ethereum/consensus-specs/blob/v1.5.0-beta.0/specs/altair/light-client/light-client.md#light-client-sync-process
proc loop(self: LightClientManager) {.async: (raises: [CancelledError]).} =
  var nextSyncTaskTime = self.getBeaconTime()

  while true:
    # Periodically wake and check for changes
    let wallTime = self.getBeaconTime()
    if wallTime < nextSyncTaskTime:
      await sleepAsync(chronos.seconds(2))
      continue

    # Obtain bootstrap data once a trusted block root is supplied
    if not self.isLightClientStoreInitialized():
      let trustedBlockRoot = self.getTrustedBlockRoot()
      if trustedBlockRoot.isNone:
        await sleepAsync(chronos.seconds(2))
        continue

      let didProgress = await self.query(Bootstrap, trustedBlockRoot.get)
      nextSyncTaskTime =
        if didProgress:
          wallTime
        else:
          wallTime + self.rng.computeDelayWithJitter(chronos.seconds(0))
      continue

    # Fetch updates
    let
      current = wallTime.slotOrZero().sync_committee_period

      syncTask = nextLightClientSyncTask(
        current = current,
        finalized = self.getFinalizedPeriod(),
        optimistic = self.getOptimisticPeriod(),
        isNextSyncCommitteeKnown = self.isNextSyncCommitteeKnown())

      didProgress =
        case syncTask.kind
        of LcSyncKind.UpdatesByRange:
          await self.query(UpdatesByRange,
            (startPeriod: syncTask.startPeriod, count: syncTask.count))
        of LcSyncKind.FinalityUpdate:
          haveFinalityUpdate = true
          await self.query(FinalityUpdate)
        of LcSyncKind.OptimisticUpdate:
          await self.query(OptimisticUpdate)

    nextSyncTaskTime =
      wallTime +
      self.rng.nextLcSyncTaskDelay(
        wallTime,
        finalized = self.getFinalizedPeriod(),
        optimistic = self.getOptimisticPeriod(),
        isNextSyncCommitteeKnown = self.isNextSyncCommitteeKnown(),
        didLatestSyncTaskProgress = didProgress
      )

proc start*(self: var LightClientManager) =
  ## Start light client manager's loop.
  doAssert self.loopFuture == nil
  self.loopFuture = self.loop()

proc stop*(self: var LightClientManager) {.async: (raises: []).} =
  ## Stop light client manager's loop.
  if self.loopFuture != nil:
    await noCancel self.loopFuture.cancelAndWait()
    self.loopFuture = nil

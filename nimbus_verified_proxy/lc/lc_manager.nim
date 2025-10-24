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
  beacon_chain/sync/[light_client_sync_helpers, sync_manager]

logScope:
  topics = "lcman"

const MAX_REQUEST_LIGHT_CLIENT_UPDATES = 128

type
  Nothing = object
  ResponseError = object of CatchableError
  Endpoint[K, V] = (K, V) # https://github.com/nim-lang/Nim/issues/19531
  Bootstrap = Endpoint[Eth2Digest, ForkedLightClientBootstrap]
  UpdatesByRange = Endpoint[
    tuple[startPeriod: SyncCommitteePeriod, count: uint64], ForkedLightClientUpdate
  ]
  FinalityUpdate = Endpoint[Nothing, ForkedLightClientFinalityUpdate]
  OptimisticUpdate = Endpoint[Nothing, ForkedLightClientOptimisticUpdate]

  NetRes*[T] = Result[T, void]
  ValueVerifier[V] = proc(v: V): Future[Result[void, LightClientVerifierError]] {.
    async: (raises: [CancelledError])
  .}
  BootstrapVerifier* = ValueVerifier[ForkedLightClientBootstrap]
  UpdateVerifier* = ValueVerifier[ForkedLightClientUpdate]
  FinalityUpdateVerifier* = ValueVerifier[ForkedLightClientFinalityUpdate]
  OptimisticUpdateVerifier* = ValueVerifier[ForkedLightClientOptimisticUpdate]

  GetTrustedBlockRootCallback* = proc(): Option[Eth2Digest] {.gcsafe, raises: [].}
  GetBoolCallback* = proc(): bool {.gcsafe, raises: [].}
  GetSlotCallback* = proc(): Slot {.gcsafe, raises: [].}

  LightClientUpdatesByRangeResponse* = NetRes[seq[ForkedLightClientUpdate]]

  LightClientBootstrapProc = proc(
    id: uint64, blockRoot: Eth2Digest
  ): Future[NetRes[ForkedLightClientBootstrap]] {.async: (raises: [CancelledError]).}
  LightClientUpdatesByRangeProc = proc(
    id: uint64, startPeriod: SyncCommitteePeriod, count: uint64
  ): Future[LightClientUpdatesByRangeResponse] {.async: (raises: [CancelledError]).}
  LightClientFinalityUpdateProc = proc(
    id: uint64
  ): Future[NetRes[ForkedLightClientFinalityUpdate]] {.
    async: (raises: [CancelledError])
  .}
  LightClientOptimisticUpdateProc = proc(
    id: uint64
  ): Future[NetRes[ForkedLightClientOptimisticUpdate]] {.
    async: (raises: [CancelledError])
  .}
  UpdateScoreProc = proc(id: uint64, value: int) {.gcsafe, raises: [].}

  EthLCBackend* = object
    getLightClientBootstrap*: LightClientBootstrapProc
    getLightClientUpdatesByRange*: LightClientUpdatesByRangeProc
    getLightClientFinalityUpdate*: LightClientFinalityUpdateProc
    getLightClientOptimisticUpdate*: LightClientOptimisticUpdateProc
    updateScore*: UpdateScoreProc

  LightClientManager* = object
    rng: ref HmacDrbgContext
    timeParams: TimeParams
    backend*: EthLCBackend
    getTrustedBlockRoot: GetTrustedBlockRootCallback
    bootstrapVerifier: BootstrapVerifier
    updateVerifier: UpdateVerifier
    finalityUpdateVerifier: FinalityUpdateVerifier
    optimisticUpdateVerifier: OptimisticUpdateVerifier
    isLightClientStoreInitialized: GetBoolCallback
    isNextSyncCommitteeKnown: GetBoolCallback
    getFinalizedSlot: GetSlotCallback
    getOptimisticSlot: GetSlotCallback
    getBeaconTime: GetBeaconTimeFn

func init*(
    T: type LightClientManager,
    rng: ref HmacDrbgContext,
    timeParams: TimeParams,
    getTrustedBlockRoot: GetTrustedBlockRootCallback,
    bootstrapVerifier: BootstrapVerifier,
    updateVerifier: UpdateVerifier,
    finalityUpdateVerifier: FinalityUpdateVerifier,
    optimisticUpdateVerifier: OptimisticUpdateVerifier,
    isLightClientStoreInitialized: GetBoolCallback,
    isNextSyncCommitteeKnown: GetBoolCallback,
    getFinalizedSlot: GetSlotCallback,
    getOptimisticSlot: GetSlotCallback,
    getBeaconTime: GetBeaconTimeFn,
): LightClientManager =
  ## Initialize light client manager.
  LightClientManager(
    rng: rng,
    timeParams: timeParams,
    getTrustedBlockRoot: getTrustedBlockRoot,
    bootstrapVerifier: bootstrapVerifier,
    updateVerifier: updateVerifier,
    finalityUpdateVerifier: finalityUpdateVerifier,
    optimisticUpdateVerifier: optimisticUpdateVerifier,
    isLightClientStoreInitialized: isLightClientStoreInitialized,
    isNextSyncCommitteeKnown: isNextSyncCommitteeKnown,
    getFinalizedSlot: getFinalizedSlot,
    getOptimisticSlot: getOptimisticSlot,
    getBeaconTime: getBeaconTime,
  )

# https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.3/specs/altair/light-client/p2p-interface.md#getlightclientbootstrap
proc doRequest(
    e: typedesc[Bootstrap], backend: EthLCBackend, reqId: uint64, blockRoot: Eth2Digest
): Future[NetRes[ForkedLightClientBootstrap]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  backend.getLightClientBootstrap(reqId, blockRoot)

# https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.3/specs/altair/light-client/p2p-interface.md#lightclientupdatesbyrange
proc doRequest(
    e: typedesc[UpdatesByRange],
    backend: EthLCBackend,
    reqId: uint64,
    key: tuple[startPeriod: SyncCommitteePeriod, count: uint64],
): Future[LightClientUpdatesByRangeResponse] {.
    async: (raises: [ResponseError, CancelledError])
.} =
  let (startPeriod, count) = key
  doAssert count > 0 and count <= MAX_REQUEST_LIGHT_CLIENT_UPDATES
  let response = await backend.getLightClientUpdatesByRange(reqId, startPeriod, count)
  if response.isOk:
    let e = distinctBase(response.get).checkLightClientUpdates(startPeriod, count)
    if e.isErr:
      raise newException(ResponseError, e.error)
  return response

# https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.3/specs/altair/light-client/p2p-interface.md#getlightclientfinalityupdate
proc doRequest(
    e: typedesc[FinalityUpdate], backend: EthLCBackend, reqId: uint64
): Future[NetRes[ForkedLightClientFinalityUpdate]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  backend.getLightClientFinalityUpdate(reqId)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/altair/light-client/p2p-interface.md#getlightclientoptimisticupdate
proc doRequest(
    e: typedesc[OptimisticUpdate], backend: EthLCBackend, reqId: uint64
): Future[NetRes[ForkedLightClientOptimisticUpdate]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  backend.getLightClientOptimisticUpdate(reqId)

template valueVerifier[E](
    self: LightClientManager, e: typedesc[E]
): ValueVerifier[E.V] =
  when E.V is ForkedLightClientBootstrap:
    self.bootstrapVerifier
  elif E.V is ForkedLightClientUpdate:
    self.updateVerifier
  elif E.V is ForkedLightClientFinalityUpdate:
    self.finalityUpdateVerifier
  elif E.V is ForkedLightClientOptimisticUpdate:
    self.optimisticUpdateVerifier
  else:
    static:
      doAssert false

iterator values(v: auto): auto =
  ## Local helper for `workerTask` to share the same implementation for both
  ## scalar and aggregate values, by treating scalars as 1-length aggregates.
  when v is seq:
    for i in v:
      yield i
  else:
    yield v

proc workerTask[E](
    self: LightClientManager, e: typedesc[E], key: E.K
): Future[bool] {.async: (raises: [CancelledError]).} =
  var
    didProgress = false
    reqId: uint64
  try:
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
                notice "Received value from an unviable fork",
                  value = forkyObject, endpoint = E.name
              else:
                notice "Received value from an unviable fork", endpoint = E.name
            self.backend.updateScore(reqId, PeerScoreUnviableFork)
            return didProgress
          of LightClientVerifierError.Invalid:
            # Descore, received data is malformed
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                warn "Received invalid value",
                  value = forkyObject.shortLog, endpoint = E.name
              else:
                warn "Received invalid value", endpoint = E.name
            self.backend.updateScore(reqId, PeerScoreBadValues)
            return didProgress
        else:
          # Reward, peer returned something useful
          applyReward = true
          didProgress = true
      if applyReward:
        self.backend.updateScore(reqId, PeerScoreGoodValues)
    else:
      self.backend.updateScore(reqId, PeerScoreNoValues)
      debug "Failed to receive value on request", value, endpoint = E.name
  except ResponseError as exc:
    self.backend.updateScore(reqId, PeerScoreBadValues)
    warn "Received invalid response", error = exc.msg, endpoint = E.name
  except CancelledError as exc:
    raise exc

  return didProgress

proc query[E](
    self: LightClientManager, e: typedesc[E], key: E.K
): Future[bool] {.async: (raises: [CancelledError]).} =
  const NUM_WORKERS = 2
  var workers: array[NUM_WORKERS, Future[bool]]

  let progressFut = Future[void].Raising([CancelledError]).init("lcmanProgress")
  var
    numCompleted = 0
    success = false
    maxCompleted = workers.len

  proc handleFinishedWorker(future: pointer) =
    try:
      let didProgress = cast[Future[bool]](future).read()
      if didProgress and not progressFut.finished:
        progressFut.complete()
        success = true
    except CatchableError:
      discard
    finally:
      inc numCompleted
      if numCompleted == maxCompleted:
        progressFut.cancelSoon()

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
    waitFor progressFut
  except CancelledError as e:
    discard # will only cancel because all workers failed

  # cancel all workers
  for i in 0 ..< NUM_WORKERS:
    workers[i].cancelSoon()

  return success

template query[E](
    self: LightClientManager, e: typedesc[E]
): Future[bool].Raising([CancelledError]) =
  self.query(e, Nothing())

# https://github.com/ethereum/consensus-specs/blob/v1.5.0-beta.0/specs/altair/light-client/light-client.md#light-client-sync-process
proc loop(self: LightClientManager) {.async: (raises: [CancelledError]).} =
  var
    downloadOptimistic = true
    downloadFinality = false
    didOptimisticProgress = false
    didFinalityProgress = false

  while true:
    let
      wallTime = self.getBeaconTime()
      currentSlot = wallTime.slotOrZero(self.timeParams)
      currentEpoch = (currentSlot mod SLOTS_PER_EPOCH)
      currentPeriod = currentSlot.sync_committee_period
      finalizedSlot = self.getFinalizedSlot()
      finalizedPeriod = finalizedSlot.sync_committee_period
      finalizedEpoch = (finalizedSlot mod SLOTS_PER_EPOCH)
      optimisticSlot = self.getOptimisticSlot()
      optimisticPeriod = optimisticSlot.sync_committee_period
      optimisitcEpoch = (optimisticSlot mod SLOTS_PER_EPOCH)

    # Obtain bootstrap data once a trusted block root is supplied
    if not self.isLightClientStoreInitialized():
      let trustedBlockRoot = self.getTrustedBlockRoot()

      # reattempt bootstrap download in 2 seconds
      if trustedBlockRoot.isNone:
        debug "TrustedBlockRoot unavaialble re-attempting bootstrap download"
        await sleepAsync(chronos.seconds(2))
        continue

      let didProgress = await self.query(Bootstrap, trustedBlockRoot.get)

      # reattempt bootstrap download in 2 seconds
      if not didProgress:
        debug "Re-attempting bootstrap download"
        await sleepAsync(chronos.seconds(2))

      continue

    # check and download sync committee updates
    if finalizedPeriod == optimisticPeriod and not self.isNextSyncCommitteeKnown():
      if finalizedPeriod >= currentPeriod:
        debug "Downloading light client sync committee updates",
          start_period = finalizedPeriod, count = 1
        discard await self.query(
          UpdatesByRange, (startPeriod: finalizedPeriod, count: uint64(1))
        )
      else:
        let count =
          min(currentPeriod - finalizedPeriod, MAX_REQUEST_LIGHT_CLIENT_UPDATES)
        debug "Downloading light client sync committee updates",
          start_period = finalizedPeriod, count = count
        discard await self.query(
          UpdatesByRange, (startPeriod: finalizedPeriod, count: uint64(count))
        )
    elif finalizedPeriod + 1 < currentPeriod:
      let count =
        min(currentPeriod - (finalizedPeriod + 1), MAX_REQUEST_LIGHT_CLIENT_UPDATES)
      debug "Downloading light client sync committee updates",
        start_period = finalizedPeriod, count = count
      discard await self.query(
        UpdatesByRange, (startPeriod: finalizedPeriod, count: uint64(count))
      )

    # check and download optimistic update
    if optimisticSlot < currentSlot:
      debug "Downloading light client optimistic updates", slot = currentSlot
      let didProgress = await self.query(OptimisticUpdate)
      if not didProgress:
        # retry in 2 seconds
        await sleepAsync(chronos.seconds(2))
        continue

    # check and download finality update
    if currentEpoch > finalizedEpoch + 2:
      debug "Downloading light client finality updates", slot = currentSlot
      let didProgress = await self.query(FinalityUpdate)
      if not didProgress:
        # retry in two seconds
        await sleepAsync(chronos.seconds(2))
        continue

    # check for updates every slot
    await sleepAsync(chronos.seconds(int64(SECONDS_PER_SLOT)))

proc start*(self: LightClientManager) {.async: (raises: [CancelledError]).} =
  ## Start light client manager's loop.
  await self.loop()

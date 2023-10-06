# beacon hain light client
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/typetraits,
  chronos, chronicles, stew/[base10, results],
  eth/p2p/discoveryv5/random2,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix, capella, deneb],
  beacon_chain/spec/[forks_light_client, digest],
  beacon_chain/beacon_clock,
  beacon_chain/sync/light_client_sync_helpers,
  "."/[beacon_light_client_network, beacon_light_client_content]

from beacon_chain/consensus_object_pools/block_pools_types import VerifierError

logScope:
  topics = "beacon_lc_man"

type
  Nothing = object
  ResponseError = object of CatchableError

  NetRes*[T] = Result[T, void]
  Endpoint[K, V] =
    (K, V) # https://github.com/nim-lang/Nim/issues/19531
  Bootstrap =
    Endpoint[Eth2Digest, ForkedLightClientBootstrap]
  UpdatesByRange =
    Endpoint[
      tuple[startPeriod: SyncCommitteePeriod, count: uint64],
      ForkedLightClientUpdate]
  FinalityUpdate =
    Endpoint[Slot, ForkedLightClientFinalityUpdate]
  OptimisticUpdate =
    Endpoint[Slot, ForkedLightClientOptimisticUpdate]

  ValueVerifier[V] =
    proc(v: V): Future[Result[void, VerifierError]] {.gcsafe, raises: [].}
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
  GetSlotCallback* =
    proc(): Slot {.gcsafe, raises: [].}

  LightClientManager* = object
    network: LightClientNetwork
    rng: ref HmacDrbgContext
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
    loopFuture: Future[void]

func init*(
    T: type LightClientManager,
    network: LightClientNetwork,
    rng: ref HmacDrbgContext,
    getTrustedBlockRoot: GetTrustedBlockRootCallback,
    bootstrapVerifier: BootstrapVerifier,
    updateVerifier: UpdateVerifier,
    finalityUpdateVerifier: FinalityUpdateVerifier,
    optimisticUpdateVerifier: OptimisticUpdateVerifier,
    isLightClientStoreInitialized: GetBoolCallback,
    isNextSyncCommitteeKnown: GetBoolCallback,
    getFinalizedSlot: GetSlotCallback,
    getOptimisticSlot: GetSlotCallback,
    getBeaconTime: GetBeaconTimeFn
): LightClientManager =
  ## Initialize light client manager.
  LightClientManager(
    network: network,
    rng: rng,
    getTrustedBlockRoot: getTrustedBlockRoot,
    bootstrapVerifier: bootstrapVerifier,
    updateVerifier: updateVerifier,
    finalityUpdateVerifier: finalityUpdateVerifier,
    optimisticUpdateVerifier: optimisticUpdateVerifier,
    isLightClientStoreInitialized: isLightClientStoreInitialized,
    isNextSyncCommitteeKnown: isNextSyncCommitteeKnown,
    getFinalizedSlot: getFinalizedSlot,
    getOptimisticSlot: getOptimisticSlot,
    getBeaconTime: getBeaconTime
  )

proc getFinalizedPeriod(self: LightClientManager): SyncCommitteePeriod =
  self.getFinalizedSlot().sync_committee_period

proc getOptimisticPeriod(self: LightClientManager): SyncCommitteePeriod =
  self.getOptimisticSlot().sync_committee_period

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#getlightclientbootstrap
proc doRequest(
    e: typedesc[Bootstrap],
    n: LightClientNetwork,
    blockRoot: Eth2Digest
): Future[NetRes[ForkedLightClientBootstrap]] =
  n.getLightClientBootstrap(blockRoot)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#lightclientupdatesbyrange
type LightClientUpdatesByRangeResponse = NetRes[ForkedLightClientUpdateList]
proc doRequest(
    e: typedesc[UpdatesByRange],
    n: LightClientNetwork,
    key: tuple[startPeriod: SyncCommitteePeriod, count: uint64]
): Future[LightClientUpdatesByRangeResponse] {.async.} =
  let (startPeriod, count) = key
  doAssert count > 0 and count <= MAX_REQUEST_LIGHT_CLIENT_UPDATES
  let response = await n.getLightClientUpdatesByRange(startPeriod, count)
  if response.isOk:
    let e = distinctBase(response.get)
      .checkLightClientUpdates(startPeriod, count)
    if e.isErr:
      raise newException(ResponseError, e.error)
  return response

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#getlightclientfinalityupdate
proc doRequest(
    e: typedesc[FinalityUpdate],
    n: LightClientNetwork,
    finalizedSlot: Slot
): Future[NetRes[ForkedLightClientFinalityUpdate]] =
  n.getLightClientFinalityUpdate(
    distinctBase(finalizedSlot)
  )

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#getlightclientoptimisticupdate
proc doRequest(
    e: typedesc[OptimisticUpdate],
    n: LightClientNetwork,
    optimisticSlot: Slot
): Future[NetRes[ForkedLightClientOptimisticUpdate]] =
  n.getLightClientOptimisticUpdate(distinctBase(optimisticSlot))

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
): Future[bool] {.async.} =
  var
    didProgress = false
  try:
    let value =
      when E.K is Nothing:
        await E.doRequest(self.network)
      else:
        await E.doRequest(self.network, key)
    if value.isOk:
      for val in value.get().values:
        let res = await self.valueVerifier(E)(val)
        if res.isErr:
          case res.error
          of VerifierError.MissingParent:
            # Stop, requires different request to progress
            return didProgress
          of VerifierError.Duplicate:
            # Ignore, a concurrent request may have already fulfilled this
            when E.V is ForkedLightClientBootstrap:
              didProgress = true
            else:
              discard
          of VerifierError.UnviableFork:
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                notice "Received value from an unviable fork",
                  value = forkyObject, endpoint = E.name
              else:
                notice "Received value from an unviable fork",
                  endpoint = E.name
            return didProgress
          of VerifierError.Invalid:
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                warn "Received invalid value", value = forkyObject.shortLog,
                  endpoint = E.name
              else:
                warn "Received invalid value", endpoint = E.name
            return didProgress
        else:
          didProgress = true
    else:
      debug "Failed to receive value on request", value, endpoint = E.name
  except ResponseError as exc:
    warn "Received invalid response", error = exc.msg, endpoint = E.name
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "Unexpected exception while receiving value", exc = exc.msg
    raise exc

  return didProgress

proc query[E](
    self: LightClientManager,
    e: typedesc[E],
    key: E.K
): Future[bool] =
  # Note:
  # The libp2p version does concurrent requests here. But it seems to be done
  # for the same key and thus as redundant request to avoid waiting on a not
  # responding peer.
  # In Portal this is already build into the lookups and thus not really
  # needed. On difference important is that the lookup concurrent requests are
  # already getting canceled when 1 peer returns the content but before the
  # content gets validated. This is improvement to do for all Portal content
  # requests however, see: https://github.com/status-im/nimbus-eth1/issues/1769
  self.workerTask(e, key)

template query[E](
    self: LightClientManager,
    e: typedesc[E]
): Future[bool] =
  self.query(e, Nothing())

type SchedulingMode = enum
  Soon,
  CurrentPeriod,
  NextPeriod

func fetchTime(
    self: LightClientManager,
    wallTime: BeaconTime,
    schedulingMode: SchedulingMode
): BeaconTime =
  let
    remainingTime =
      case schedulingMode:
      of Soon:
        chronos.seconds(0)
      of CurrentPeriod:
        let
          wallPeriod = wallTime.slotOrZero().sync_committee_period
          deadlineSlot = (wallPeriod + 1).start_slot - 1
          deadline = deadlineSlot.start_beacon_time()
        chronos.nanoseconds((deadline - wallTime).nanoseconds)
      of NextPeriod:
        chronos.seconds(
          (SLOTS_PER_SYNC_COMMITTEE_PERIOD * SECONDS_PER_SLOT).int64)
    minDelay = max(remainingTime div 8, chronos.seconds(10))
    jitterSeconds = (minDelay * 2).seconds
    jitterDelay = chronos.seconds(self.rng[].rand(jitterSeconds).int64)
  return wallTime + minDelay + jitterDelay

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/light-client.md#light-client-sync-process
proc loop(self: LightClientManager) {.async.} =
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
          discard
          await self.query(UpdatesByRange,
            (startPeriod: syncTask.startPeriod, count: syncTask.count))
        of LcSyncKind.FinalityUpdate:
          let finalizedSlot = start_slot(epoch(wallTime.slotOrZero()) - 2)
          await self.query(FinalityUpdate, finalizedSlot)
        of LcSyncKind.OptimisticUpdate:
          let optimisticSlot = wallTime.slotOrZero() - 1
          await self.query(OptimisticUpdate, optimisticSlot)

    nextSyncTaskTime = wallTime + self.rng.nextLcSyncTaskDelay(
      wallTime,
      finalized = self.getFinalizedPeriod(),
      optimistic = self.getOptimisticPeriod(),
      isNextSyncCommitteeKnown = self.isNextSyncCommitteeKnown(),
      didLatestSyncTaskProgress = didProgress)

proc start*(self: var LightClientManager) =
  ## Start light client manager's loop.
  doAssert self.loopFuture == nil
  self.loopFuture = self.loop()

proc stop*(self: var LightClientManager) {.async.} =
  ## Stop light client manager's loop.
  if self.loopFuture != nil:
    await self.loopFuture.cancelAndWait()
    self.loopFuture = nil

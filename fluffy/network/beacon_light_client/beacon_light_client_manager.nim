# beacon hain light client
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.


{.push raises: [Defect].}

import
  std/typetraits,
  chronos, chronicles, stew/[base10, results],
  eth/p2p/discoveryv5/random2,
  beacon_chain/spec/datatypes/altair,
  beacon_chain/beacon_clock,
  "."/[light_client_network, light_client_content]

from beacon_chain/consensus_object_pools/block_pools_types import BlockError

logScope:
  topics = "lcman"

type
  Nothing = object
  NetRes*[T] = Result[T, void]
  Endpoint[K, V] =
    (K, V) # https://github.com/nim-lang/Nim/issues/19531
  Bootstrap =
    Endpoint[Eth2Digest, altair.LightClientBootstrap]
  UpdatesByRange =
    Endpoint[Slice[SyncCommitteePeriod], altair.LightClientUpdate]
  FinalityUpdate =
    Endpoint[Nothing, altair.LightClientFinalityUpdate]
  OptimisticUpdate =
    Endpoint[Nothing, altair.LightClientOptimisticUpdate]

  ValueVerifier[V] =
    proc(v: V): Future[Result[void, BlockError]] {.gcsafe, raises: [Defect].}
  BootstrapVerifier* =
    ValueVerifier[altair.LightClientBootstrap]
  UpdateVerifier* =
    ValueVerifier[altair.LightClientUpdate]
  FinalityUpdateVerifier* =
    ValueVerifier[altair.LightClientFinalityUpdate]
  OptimisticUpdateVerifier* =
    ValueVerifier[altair.LightClientOptimisticUpdate]

  GetTrustedBlockRootCallback* =
    proc(): Option[Eth2Digest] {.gcsafe, raises: [Defect].}
  GetBoolCallback* =
    proc(): bool {.gcsafe, raises: [Defect].}
  GetSyncCommitteePeriodCallback* =
    proc(): SyncCommitteePeriod {.gcsafe, raises: [Defect].}

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
    getFinalizedPeriod: GetSyncCommitteePeriodCallback
    getOptimisticPeriod: GetSyncCommitteePeriodCallback
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
    getFinalizedPeriod: GetSyncCommitteePeriodCallback,
    getOptimisticPeriod: GetSyncCommitteePeriodCallback,
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
    getFinalizedPeriod: getFinalizedPeriod,
    getOptimisticPeriod: getOptimisticPeriod,
    getBeaconTime: getBeaconTime
  )

proc isGossipSupported*(
    self: LightClientManager,
    period: SyncCommitteePeriod
): bool =
  ## Indicate whether the light client is sufficiently synced to accept gossip.
  if not self.isLightClientStoreInitialized():
    return false

  let
    finalizedPeriod = self.getFinalizedPeriod()
    isNextSyncCommitteeKnown = self.isNextSyncCommitteeKnown()
  if isNextSyncCommitteeKnown:
    period <= finalizedPeriod + 1
  else:
    period <= finalizedPeriod

# https://github.com/ethereum/consensus-specs/blob/v1.2.0/specs/altair/light-client/p2p-interface.md#getlightclientbootstrap
proc doRequest(
    e: typedesc[Bootstrap],
    n: LightClientNetwork,
    blockRoot: Eth2Digest
): Future[NetRes[altair.LightClientBootstrap]] =
  n.getLightClientBootstrap(blockRoot)

# https://github.com/ethereum/consensus-specs/blob/v1.2.0/specs/altair/light-client/p2p-interface.md#lightclientupdatesbyrange
type LightClientUpdatesByRangeResponse = NetRes[seq[altair.LightClientUpdate]]
proc doRequest(
    e: typedesc[UpdatesByRange],
    n: LightClientNetwork,
    periods: Slice[SyncCommitteePeriod]
): Future[LightClientUpdatesByRangeResponse] =
  let
    startPeriod = periods.a
    lastPeriod = periods.b
    reqCount = min(periods.len, MAX_REQUEST_LIGHT_CLIENT_UPDATES).uint64
  n.getLightClientUpdatesByRange(
    distinctBase(startPeriod),
    reqCount
  )

# https://github.com/ethereum/consensus-specs/blob/v1.2.0/specs/altair/light-client/p2p-interface.md#getlightclientfinalityupdate
proc doRequest(
    e: typedesc[FinalityUpdate],
    n: LightClientNetwork
): Future[NetRes[altair.LightClientFinalityUpdate]] =
  n.getLightClientFinalityUpdate()

# https://github.com/ethereum/consensus-specs/blob/v1.2.0/specs/altair/light-client/p2p-interface.md#getlightclientoptimisticupdate
proc doRequest(
    e: typedesc[OptimisticUpdate],
    n: LightClientNetwork
): Future[NetRes[altair.LightClientOptimisticUpdate]] =
  n.getLightClientOptimisticUpdate()

template valueVerifier[E](
    self: LightClientManager,
    e: typedesc[E]
): ValueVerifier[E.V] =
  when E.V is altair.LightClientBootstrap:
    self.bootstrapVerifier
  elif E.V is altair.LightClientUpdate:
    self.updateVerifier
  elif E.V is altair.LightClientFinalityUpdate:
    self.finalityUpdateVerifier
  elif E.V is altair.LightClientOptimisticUpdate:
    self.optimisticUpdateVerifier
  else: static: doAssert false

iterator values(v: auto): auto =
  ## Local helper for `workerTask` to share the same implementation for both
  ## scalar and aggregate values, by treating scalars as 1-length aggregates.
  when v is seq:
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
      for val in value.get.values:
        let res = await self.valueVerifier(E)(val)
        if res.isErr:
          case res.error
          of BlockError.MissingParent:
            # Stop, requires different request to progress
            return didProgress
          of BlockError.Duplicate:
            # Ignore, a concurrent request may have already fulfilled this
            when E.V is altair.LightClientBootstrap:
              didProgress = true
            else:
              discard
          of BlockError.UnviableFork:
            notice "Received value from an unviable fork", value = val.shortLog
            return didProgress
          of BlockError.Invalid:
            warn "Received invalid value", value = val.shortLog
            return didProgress
        else:
          didProgress = true
    else:
      debug "Failed to receive value on request", value
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
  # TODO Consider making few requests concurrently
  return self.workertask(e, key)

template query(
    self: LightClientManager,
    e: typedesc[UpdatesByRange],
    key: SyncCommitteePeriod
): Future[bool] =
  self.query(e, key .. key)

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

# https://github.com/ethereum/consensus-specs/blob/v1.2.0/specs/altair/light-client/light-client.md#light-client-sync-process
proc loop(self: LightClientManager) {.async.} =
  var nextFetchTime = self.getBeaconTime()
  while true:
    # Periodically wake and check for changes
    let wallTime = self.getBeaconTime()
    if wallTime < nextFetchTime:
      await sleepAsync(chronos.seconds(2))
      continue

    # Obtain bootstrap data once a trusted block root is supplied
    if not self.isLightClientStoreInitialized():
      let trustedBlockRoot = self.getTrustedBlockRoot()
      if trustedBlockRoot.isNone:
        await sleepAsync(chronos.seconds(2))
        continue

      let didProgress = await self.query(Bootstrap, trustedBlockRoot.get)
      if not didProgress:
        nextFetchTime = self.fetchTime(wallTime, Soon)
      continue

    # Fetch updates
    var allowWaitNextPeriod = false
    let
      finalized = self.getFinalizedPeriod()
      optimistic = self.getOptimisticPeriod()
      current = wallTime.slotOrZero().sync_committee_period
      isNextSyncCommitteeKnown = self.isNextSyncCommitteeKnown()

      didProgress =
        if finalized == optimistic and not isNextSyncCommitteeKnown:
          if finalized >= current:
            await self.query(UpdatesByRange, finalized)
          else:
            await self.query(UpdatesByRange, finalized ..< current)
        elif finalized + 1 < current:
          await self.query(UpdatesByRange, finalized + 1 ..< current)
        elif finalized != optimistic:
          await self.query(FinalityUpdate)
        else:
          allowWaitNextPeriod = true
          await self.query(OptimisticUpdate)

      schedulingMode =
        if not didProgress or not self.isGossipSupported(current):
          Soon
        elif not allowWaitNextPeriod:
          CurrentPeriod
        else:
          NextPeriod

    nextFetchTime = self.fetchTime(wallTime, schedulingMode)

proc start*(self: var LightClientManager) =
  ## Start light client manager's loop.
  doAssert self.loopFuture == nil
  self.loopFuture = self.loop()

proc stop*(self: var LightClientManager) {.async.} =
  ## Stop light client manager's loop.
  if self.loopFuture != nil:
    await self.loopFuture.cancelAndWait()
    self.loopFuture = nil

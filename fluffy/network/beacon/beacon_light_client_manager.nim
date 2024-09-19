# fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/typetraits,
  chronos,
  chronicles,
  stew/base10,
  results,
  eth/p2p/discoveryv5/random2,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix, capella, deneb, electra],
  beacon_chain/spec/[forks_light_client, digest],
  beacon_chain/beacon_clock,
  beacon_chain/sync/light_client_sync_helpers,
  "."/[beacon_network, beacon_content, beacon_db]

from beacon_chain/consensus_object_pools/block_pools_types import VerifierError

logScope:
  topics = "beacon_lc_man"

type
  Nothing = object
  ResponseError = object of CatchableError

  NetRes*[T] = Result[T, void]
  Endpoint[K, V] = (K, V) # https://github.com/nim-lang/Nim/issues/19531
  Bootstrap = Endpoint[Eth2Digest, ForkedLightClientBootstrap]
  UpdatesByRange = Endpoint[
    tuple[startPeriod: SyncCommitteePeriod, count: uint64], ForkedLightClientUpdate
  ]
  FinalityUpdate = Endpoint[Slot, ForkedLightClientFinalityUpdate]
  OptimisticUpdate = Endpoint[Slot, ForkedLightClientOptimisticUpdate]

  ValueVerifier[V] = proc(v: V): Future[Result[void, VerifierError]] {.
    async: (raises: [CancelledError], raw: true)
  .}
  BootstrapVerifier* = ValueVerifier[ForkedLightClientBootstrap]
  UpdateVerifier* = ValueVerifier[ForkedLightClientUpdate]
  FinalityUpdateVerifier* = ValueVerifier[ForkedLightClientFinalityUpdate]
  OptimisticUpdateVerifier* = ValueVerifier[ForkedLightClientOptimisticUpdate]

  GetTrustedBlockRootCallback* = proc(): Option[Eth2Digest] {.gcsafe, raises: [].}
  GetBoolCallback* = proc(): bool {.gcsafe, raises: [].}
  GetSlotCallback* = proc(): Slot {.gcsafe, raises: [].}

  LightClientManager* = object
    network: BeaconNetwork
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
    network: BeaconNetwork,
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
    getBeaconTime: GetBeaconTimeFn,
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
    getBeaconTime: getBeaconTime,
  )

proc getFinalizedPeriod(self: LightClientManager): SyncCommitteePeriod =
  self.getFinalizedSlot().sync_committee_period

proc getOptimisticPeriod(self: LightClientManager): SyncCommitteePeriod =
  self.getOptimisticSlot().sync_committee_period

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#getlightclientbootstrap
proc doRequest(
    e: typedesc[Bootstrap], n: BeaconNetwork, blockRoot: Eth2Digest
): Future[NetRes[ForkedLightClientBootstrap]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  n.getLightClientBootstrap(blockRoot)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#lightclientupdatesbyrange
type LightClientUpdatesByRangeResponse = NetRes[ForkedLightClientUpdateList]
proc doRequest(
    e: typedesc[UpdatesByRange],
    n: BeaconNetwork,
    key: tuple[startPeriod: SyncCommitteePeriod, count: uint64],
): Future[LightClientUpdatesByRangeResponse] {.
    async: (raises: [ResponseError, CancelledError])
.} =
  let (startPeriod, count) = key
  doAssert count > 0 and count <= MAX_REQUEST_LIGHT_CLIENT_UPDATES
  let response = await n.getLightClientUpdatesByRange(startPeriod, count)
  if response.isOk:
    let e = distinctBase(response.get).checkLightClientUpdates(startPeriod, count)
    if e.isErr:
      raise newException(ResponseError, e.error)
  return response

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#getlightclientfinalityupdate
proc doRequest(
    e: typedesc[FinalityUpdate], n: BeaconNetwork, finalizedSlot: Slot
): Future[NetRes[ForkedLightClientFinalityUpdate]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  n.getLightClientFinalityUpdate(distinctBase(finalizedSlot))

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/p2p-interface.md#getlightclientoptimisticupdate
proc doRequest(
    e: typedesc[OptimisticUpdate], n: BeaconNetwork, optimisticSlot: Slot
): Future[NetRes[ForkedLightClientOptimisticUpdate]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  n.getLightClientOptimisticUpdate(distinctBase(optimisticSlot))

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
  when v is List:
    for i in v:
      yield i
  else:
    yield v

proc workerTask[E](
    self: LightClientManager, e: typedesc[E], key: E.K
): Future[bool] {.async: (raises: [CancelledError]).} =
  var didProgress = false
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
                notice "Received value from an unviable fork", endpoint = E.name
            return didProgress
          of VerifierError.Invalid:
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                warn "Received invalid value",
                  value = forkyObject.shortLog, endpoint = E.name
              else:
                warn "Received invalid value", endpoint = E.name
            return didProgress
        else:
          # TODO:
          # This is data coming from either the network or the database.
          # Either way it comes in encoded and is passed along till here in its
          # decoded format. It only gets stored in the database here as it is
          # required to pass validation first ( didprogress == true). Next it
          # gets encoded again before dropped in the database. Optimisations
          # are possible here if the beacon_light_client_manager and the
          # manager are better interfaced with each other.
          when E.V is ForkedLightClientBootstrap:
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                self.network.beaconDb.putBootstrap(key, val)
              else:
                notice "Received value from an unviable fork", endpoint = E.name
          elif E.V is ForkedLightClientUpdate:
            withForkyObject(val):
              when lcDataFork > LightClientDataFork.None:
                let period =
                  forkyObject.attested_header.beacon.slot.sync_committee_period
                self.network.beaconDb.putUpdateIfBetter(period, val)
              else:
                notice "Received value from an unviable fork", endpoint = E.name

          didProgress = true
    else:
      debug "Failed to receive value on request", value, endpoint = E.name
  except ResponseError as exc:
    warn "Received invalid response", error = exc.msg, endpoint = E.name
  except CancelledError as exc:
    raise exc

  return didProgress

proc query[E](
    self: LightClientManager, e: typedesc[E], key: E.K
): Future[bool] {.async: (raises: [CancelledError], raw: true).} =
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

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.1/specs/altair/light-client/light-client.md#light-client-sync-process
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
        isNextSyncCommitteeKnown = self.isNextSyncCommitteeKnown(),
      )

      didProgress =
        case syncTask.kind
        of LcSyncKind.UpdatesByRange:
          await self.query(
            UpdatesByRange, (startPeriod: syncTask.startPeriod, count: syncTask.count)
          )
        of LcSyncKind.FinalityUpdate:
          let finalizedSlot = start_slot(epoch(wallTime.slotOrZero()) - 2)
          await self.query(FinalityUpdate, finalizedSlot)
        of LcSyncKind.OptimisticUpdate:
          let optimisticSlot = wallTime.slotOrZero()
          await self.query(OptimisticUpdate, optimisticSlot)

    nextSyncTaskTime =
      wallTime +
      self.rng.nextLcSyncTaskDelay(
        wallTime,
        finalized = self.getFinalizedPeriod(),
        optimistic = self.getOptimisticPeriod(),
        isNextSyncCommitteeKnown = self.isNextSyncCommitteeKnown(),
        didLatestSyncTaskProgress = didProgress,
      )

proc start*(self: var LightClientManager) =
  ## Start light client manager's loop.
  doAssert self.loopFuture == nil
  self.loopFuture = self.loop()

proc stop*(self: var LightClientManager) {.async: (raises: []).} =
  ## Stop light client manager's loop.
  if not self.loopFuture.isNil():
    await noCancel(self.loopFuture.cancelAndWait())
    self.loopFuture = nil

# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  chronos,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/beacon_clock,
  ./lc_manager # use the modified light client manager

type
  LightClientHeaderCallback* = proc(
    lightClient: LightClient, header: ForkedLightClientHeader
  ) {.gcsafe, raises: [].}

  LightClient* = ref object
    cfg: RuntimeConfig
    forkDigests: ref ForkDigests
    getBeaconTime*: GetBeaconTimeFn
    store*: ref ForkedLightClientStore
    processor*: ref LightClientProcessor
    manager: LightClientManager
    onFinalizedHeader*, onOptimisticHeader*: LightClientHeaderCallback
    trustedBlockRoot*: Option[Eth2Digest]

func getFinalizedHeader*(lightClient: LightClient): ForkedLightClientHeader =
  withForkyStore(lightClient.store[]):
    when lcDataFork > LightClientDataFork.None:
      var header = ForkedLightClientHeader(kind: lcDataFork)
      header.forky(lcDataFork) = forkyStore.finalized_header
      header
    else:
      default(ForkedLightClientHeader)

func getOptimisticHeader*(lightClient: LightClient): ForkedLightClientHeader =
  withForkyStore(lightClient.store[]):
    when lcDataFork > LightClientDataFork.None:
      var header = ForkedLightClientHeader(kind: lcDataFork)
      header.forky(lcDataFork) = forkyStore.optimistic_header
      header
    else:
      default(ForkedLightClientHeader)

proc new*(
    T: type LightClient,
    rng: ref HmacDrbgContext,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
    getBeaconTime: GetBeaconTimeFn,
    genesis_validators_root: Eth2Digest,
    finalizationMode: LightClientFinalizationMode,
): T =
  let lightClient = LightClient(
    cfg: cfg,
    forkDigests: forkDigests,
    getBeaconTime: getBeaconTime,
    store: (ref ForkedLightClientStore)(),
  )

  func getTrustedBlockRoot(): Option[Eth2Digest] =
    lightClient.trustedBlockRoot

  proc onStoreInitialized() =
    discard

  proc onFinalizedHeader() =
    if lightClient.onFinalizedHeader != nil:
      lightClient.onFinalizedHeader(lightClient, lightClient.getFinalizedHeader)

  proc onOptimisticHeader() =
    if lightClient.onOptimisticHeader != nil:
      lightClient.onOptimisticHeader(lightClient, lightClient.getOptimisticHeader)

  # initialize without dumping 
  lightClient.processor = LightClientProcessor.new(
    false, ".", ".", cfg, genesis_validators_root, finalizationMode, lightClient.store,
    getBeaconTime, getTrustedBlockRoot, onStoreInitialized, onFinalizedHeader,
    onOptimisticHeader,
  )

  proc lightClientVerifier(
      obj: SomeForkedLightClientObject
  ): Future[Result[void, LightClientVerifierError]] {.
      async: (raises: [CancelledError], raw: true)
  .} =
    let resfut = Future[Result[void, LightClientVerifierError]]
      .Raising([CancelledError])
      .init("lightClientVerifier")
    lightClient.processor[].addObject(MsgSource.gossip, obj, resfut)
    resfut

  proc bootstrapVerifier(obj: ForkedLightClientBootstrap): auto =
    lightClientVerifier(obj)

  proc updateVerifier(obj: ForkedLightClientUpdate): auto =
    lightClientVerifier(obj)

  proc finalityVerifier(obj: ForkedLightClientFinalityUpdate): auto =
    lightClientVerifier(obj)

  proc optimisticVerifier(obj: ForkedLightClientOptimisticUpdate): auto =
    lightClientVerifier(obj)

  func isLightClientStoreInitialized(): bool =
    lightClient.store[].kind > LightClientDataFork.None

  func isNextSyncCommitteeKnown(): bool =
    withForkyStore(lightClient.store[]):
      when lcDataFork > LightClientDataFork.None:
        forkyStore.is_next_sync_committee_known
      else:
        false

  func getFinalizedSlot(): Slot =
    withForkyStore(lightClient.store[]):
      when lcDataFork > LightClientDataFork.None:
        forkyStore.finalized_header.beacon.slot
      else:
        GENESIS_SLOT

  func getOptimisticSlot(): Slot =
    withForkyStore(lightClient.store[]):
      when lcDataFork > LightClientDataFork.None:
        forkyStore.optimistic_header.beacon.slot
      else:
        GENESIS_SLOT

  lightClient.manager = LightClientManager.init(
    rng, cfg.timeParams, getTrustedBlockRoot, bootstrapVerifier, updateVerifier,
    finalityVerifier, optimisticVerifier, isLightClientStoreInitialized,
    isNextSyncCommitteeKnown, getFinalizedSlot, getOptimisticSlot, getBeaconTime,
  )

  lightClient

proc setBackend*(lightClient: LightClient, backend: EthLCBackend) =
  lightClient.manager.backend = backend

proc start*(lightClient: LightClient) =
  info "Starting beacon light client", trusted_block_root = lightClient.trustedBlockRoot
  lightClient.manager.start()

proc stop*(lightClient: LightClient) {.async: (raises: []).} =
  info "Stopping beacon light client"
  await lightClient.manager.stop()

proc resetToFinalizedHeader*(
    lightClient: LightClient,
    header: ForkedLightClientHeader,
    current_sync_committee: SyncCommittee,
) =
  lightClient.processor[].resetToFinalizedHeader(header, current_sync_committee)

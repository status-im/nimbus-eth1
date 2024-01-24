# Nimbus - Portal Network
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  eth/p2p/discoveryv5/random2,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/spec/datatypes/altair,
  beacon_chain/beacon_clock,
  "."/[beacon_init_loader, beacon_network, beacon_light_client_manager]

export
  LightClientFinalizationMode,
  beacon_network, beacon_light_client_manager

logScope: topics = "beacon_lc"

type
  LightClientHeaderCallback* =
    proc(lightClient: LightClient, header: ForkedLightClientHeader) {.
      gcsafe, raises: [].}

  LightClient* = ref object
    network*: BeaconNetwork
    cfg: RuntimeConfig
    forkDigests: ref ForkDigests
    getBeaconTime*: GetBeaconTimeFn
    store*: ref ForkedLightClientStore
    processor*: ref LightClientProcessor
    manager: LightClientManager
    onFinalizedHeader*, onOptimisticHeader*: LightClientHeaderCallback
    trustedBlockRoot*: Option[Eth2Digest]

func finalizedHeader*(
    lightClient: LightClient): ForkedLightClientHeader =
  withForkyStore(lightClient.store[]):
    when lcDataFork > LightClientDataFork.None:
      var header = ForkedLightClientHeader(kind: lcDataFork)
      header.forky(lcDataFork) = forkyStore.finalized_header
      header
    else:
      default(ForkedLightClientHeader)

func optimisticHeader*(
    lightClient: LightClient): ForkedLightClientHeader =
  withForkyStore(lightClient.store[]):
    when lcDataFork > LightClientDataFork.None:
      var header = ForkedLightClientHeader(kind: lcDataFork)
      header.forky(lcDataFork) = forkyStore.optimistic_header
      header
    else:
      default(ForkedLightClientHeader)

proc new*(
    T: type LightClient,
    network: BeaconNetwork,
    rng: ref HmacDrbgContext,
    dumpEnabled: bool,
    dumpDirInvalid, dumpDirIncoming: string,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
    getBeaconTime: GetBeaconTimeFn,
    genesis_validators_root: Eth2Digest,
    finalizationMode: LightClientFinalizationMode): T =
  let lightClient = LightClient(
    network: network,
    cfg: cfg,
    forkDigests: forkDigests,
    getBeaconTime: getBeaconTime,
    store: (ref ForkedLightClientStore)())

  func getTrustedBlockRoot(): Option[Eth2Digest] =
    lightClient.trustedBlockRoot

  proc onStoreInitialized() =
    discard

  proc onFinalizedHeader() =
    if lightClient.onFinalizedHeader != nil:
      lightClient.onFinalizedHeader(
        lightClient, lightClient.finalizedHeader)

  proc onOptimisticHeader() =
    if lightClient.onOptimisticHeader != nil:
      lightClient.onOptimisticHeader(
        lightClient, lightClient.optimisticHeader)

  lightClient.processor = LightClientProcessor.new(
    dumpEnabled, dumpDirInvalid, dumpDirIncoming,
    cfg, genesis_validators_root, finalizationMode,
    lightClient.store, getBeaconTime, getTrustedBlockRoot,
    onStoreInitialized, onFinalizedHeader, onOptimisticHeader)

  proc lightClientVerifier(obj: SomeForkedLightClientObject):
      Future[Result[void, VerifierError]] =
    let resfut = Future[Result[void, VerifierError]].Raising([CancelledError]).init("lightClientVerifier")
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
    lightClient.network, rng, getTrustedBlockRoot,
    bootstrapVerifier, updateVerifier, finalityVerifier, optimisticVerifier,
    isLightClientStoreInitialized, isNextSyncCommitteeKnown,
    getFinalizedSlot, getOptimisticSlot, getBeaconTime)

  lightClient

proc new*(
    T: type LightClient,
    network: BeaconNetwork,
    rng: ref HmacDrbgContext,
    networkData: NetworkInitData,
    finalizationMode: LightClientFinalizationMode): T =
  let
    getBeaconTime = networkData.clock.getBeaconTimeFn()
    forkDigests = newClone networkData.forks

  LightClient.new(
    network, rng,
    dumpEnabled = false, dumpDirInvalid = ".", dumpDirIncoming = ".",
    networkData.metadata.cfg, forkDigests, getBeaconTime,
    networkData.genesis_validators_root, finalizationMode)

proc start*(lightClient: LightClient) =
  notice "Starting beacon light client",
    trusted_block_root = lightClient.trustedBlockRoot
  lightClient.manager.start()

proc resetToFinalizedHeader*(
    lightClient: LightClient,
    header: ForkedLightClientHeader,
    current_sync_committee: altair.SyncCommittee) =
  lightClient.processor[].resetToFinalizedHeader(header, current_sync_committee)


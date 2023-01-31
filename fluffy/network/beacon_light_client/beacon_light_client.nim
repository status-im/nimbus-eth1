# beacon hain light client
# Copyright (c) 2022 Status Research & Development GmbH
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
  "."/[light_client_network, beacon_light_client_manager]

export LightClientFinalizationMode

logScope: topics = "lightcl"

type
  LightClientHeaderCallback* =
    proc(lightClient: LightClient, header: BeaconBlockHeader) {.
      gcsafe, raises: [Defect].}

  LightClient* = ref object
    network: LightClientNetwork
    cfg: RuntimeConfig
    forkDigests: ref ForkDigests
    getBeaconTime: GetBeaconTimeFn
    store: ref Option[LightClientStore]
    processor: ref LightClientProcessor
    manager: LightClientManager
    onFinalizedHeader*, onOptimisticHeader*: LightClientHeaderCallback
    trustedBlockRoot*: Option[Eth2Digest]

func finalizedHeader*(lightClient: LightClient): Opt[BeaconBlockHeader] =
  if lightClient.store[].isSome:
    ok lightClient.store[].get.finalized_header
  else:
    err()

func optimisticHeader*(lightClient: LightClient): Opt[BeaconBlockHeader] =
  if lightClient.store[].isSome:
    ok lightClient.store[].get.optimistic_header
  else:
    err()

proc new*(
    T: type LightClient,
    network: LightClientNetwork,
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
    store: (ref Option[LightClientStore])())

  func getTrustedBlockRoot(): Option[Eth2Digest] =
    lightClient.trustedBlockRoot

  proc onStoreInitialized() =
    discard

  proc onFinalizedHeader() =
    if lightClient.onFinalizedHeader != nil:
      lightClient.onFinalizedHeader(
        lightClient, lightClient.finalizedHeader.get)

  proc onOptimisticHeader() =
    if lightClient.onOptimisticHeader != nil:
      lightClient.onOptimisticHeader(
        lightClient, lightClient.optimisticHeader.get)

  lightClient.processor = LightClientProcessor.new(
    dumpEnabled, dumpDirInvalid, dumpDirIncoming,
    cfg, genesis_validators_root, finalizationMode,
    lightClient.store, getBeaconTime, getTrustedBlockRoot,
    onStoreInitialized, onFinalizedHeader, onOptimisticHeader)

  proc lightClientVerifier(obj: SomeLightClientObject):
      Future[Result[void, VerifierError]] =
    let resfut = newFuture[Result[void, VerifierError]]("lightClientVerifier")
    lightClient.processor[].addObject(MsgSource.gossip, obj, resfut)
    resfut

  proc bootstrapVerifier(obj: altair.LightClientBootstrap): auto =
    lightClientVerifier(obj)
  proc updateVerifier(obj: altair.LightClientUpdate): auto =
    lightClientVerifier(obj)
  proc finalityVerifier(obj: altair.LightClientFinalityUpdate): auto =
    lightClientVerifier(obj)
  proc optimisticVerifier(obj: altair.LightClientOptimisticUpdate): auto =
    lightClientVerifier(obj)

  func isLightClientStoreInitialized(): bool =
    lightClient.store[].isSome

  func isNextSyncCommitteeKnown(): bool =
    if lightClient.store[].isSome:
      lightClient.store[].get.is_next_sync_committee_known
    else:
      false

  func getFinalizedSlot(): Slot =
    if lightClient.store[].isSome:
      lightClient.store[].get.finalized_header.slot
    else:
      GENESIS_SLOT

  func getOptimistiSlot(): Slot =
    if lightClient.store[].isSome:
      lightClient.store[].get.optimistic_header.slot
    else:
      GENESIS_SLOT

  lightClient.manager = LightClientManager.init(
    lightClient.network, rng, getTrustedBlockRoot,
    bootstrapVerifier, updateVerifier, finalityVerifier, optimisticVerifier,
    isLightClientStoreInitialized, isNextSyncCommitteeKnown,
    getFinalizedSlot, getOptimistiSlot, getBeaconTime)

  lightClient

proc new*(
    T: type LightClient,
    network: LightClientNetwork,
    rng: ref HmacDrbgContext,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
    getBeaconTime: GetBeaconTimeFn,
    genesis_validators_root: Eth2Digest,
    finalizationMode: LightClientFinalizationMode): T =
  LightClient.new(
    network, rng,
    dumpEnabled = false, dumpDirInvalid = ".", dumpDirIncoming = ".",
    cfg, forkDigests, getBeaconTime, genesis_validators_root, finalizationMode
  )

proc start*(lightClient: LightClient) =
  notice "Starting light client",
    trusted_block_root = lightClient.trustedBlockRoot
  lightClient.manager.start()

proc resetToFinalizedHeader*(
    lightClient: LightClient,
    header: BeaconBlockHeader,
    current_sync_committee: SyncCommittee) =
  lightClient.processor[].resetToFinalizedHeader(header, current_sync_committee)


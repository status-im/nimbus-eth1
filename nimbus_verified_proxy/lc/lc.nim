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
  eth/common/keys, # used for keys.rng
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/[beacon_clock, conf],
  ./lc_manager # use the modified light client manager

type
  LightClientHeaderCallback* = proc(
    lightClient: LightClient, header: ForkedLightClientHeader
  ) {.gcsafe, raises: [].}

  LightClient* = ref object
    cfg*: RuntimeConfig
    forkDigests*: ref ForkDigests
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

  const
    dumpEnabled = false
    dumpDirInvalid = "."
    dumpDirIncoming = "."

  # initialize without dumping 
  lightClient.processor = LightClientProcessor.new(
    dumpEnabled, dumpDirInvalid, dumpDirIncoming, cfg, genesis_validators_root,
    finalizationMode, lightClient.store, getBeaconTime, getTrustedBlockRoot,
    onStoreInitialized, onFinalizedHeader, onOptimisticHeader,
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

proc new*(
    T: type LightClient, chain: Option[string], trustedBlockRoot: Option[Eth2Digest]
): T =
  let metadata = loadEth2Network(chain)

  # just for short hand convenience
  template cfg(): auto =
    metadata.cfg

  # initialize beacon node genesis data, beacon clock and forkDigests
  let
    genesisState =
      try:
        template genesisData(): auto =
          metadata.genesis.bakedBytes

        newClone(
          readSszForkedHashedBeaconState(
            cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)
          )
        )
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    # getStateField reads seeks info directly from a byte array
    # get genesis time and instantiate the beacon clock
    genesisTime = genesisState[].genesis_time
    beaconClock = BeaconClock.init(cfg.timeParams, genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure

    # get the function that itself get the current beacon time
    getBeaconTime = beaconClock.getBeaconTimeFn()
    genesis_validators_root = genesisState[].genesis_validators_root
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    rng = keys.newRng()

    # light client is set to optimistic finalization mode
    lightClient = LightClient.new(
      rng, cfg, forkDigests, getBeaconTime, genesis_validators_root,
      LightClientFinalizationMode.Optimistic,
    )

  lightClient.trustedBlockRoot = trustedBlockRoot
  lightClient

proc setBackend*(lightClient: LightClient, backend: EthLCBackend) =
  lightClient.manager.backend = backend

proc start*(lightClient: LightClient) {.async: (raises: [CancelledError]).} =
  info "Starting beacon light client", trusted_block_root = lightClient.trustedBlockRoot
  await lightClient.manager.start()

proc resetToFinalizedHeader*(
    lightClient: LightClient,
    header: ForkedLightClientHeader,
    current_sync_committee: SyncCommittee,
) =
  lightClient.processor[].resetToFinalizedHeader(header, current_sync_committee)

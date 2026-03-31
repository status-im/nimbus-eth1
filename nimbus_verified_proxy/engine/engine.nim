# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[options, random],
  chronicles,
  chronos,
  stew/byteutils,
  eth/common/[hashes, headers, addresses],
  beacon_chain/spec/forks,
  beacon_chain/spec/beaconstate,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/beacon_clock,
  beacon_chain/sync/light_client_sync_helpers,
  beacon_chain/networking/network_metadata,
  beacon_chain/el/engine_api_conversions,
  beacon_chain/conf,
  ./types,
  ./utils,
  ./header_store,
  ./evm

from eth/common/blocks import EMPTY_UNCLE_HASH

const MAX_REQUEST_LIGHT_CLIENT_UPDATES* = 128

func convLCHeader*(lcHeader: ForkyLightClientHeader): Result[Header, string] =
  when lcHeader is altair.LightClientHeader:
    err("pre-bellatrix light client headers do not have execution header")
  else:
    template p(): auto =
      lcHeader.execution

    when lcHeader is deneb.LightClientHeader or lcHeader is electra.LightClientHeader:
      let
        blobGasUsed = Opt.some(p.blob_gas_used)
        excessBlobGas = Opt.some(p.excess_blob_gas)
        parentBeaconBlockRoot = Opt.some(lcHeader.beacon.parent_root.asBlockHash)
    else:
      const
        blobGasUsed = Opt.none(uint64)
        excessBlobGas = Opt.none(uint64)
        parentBeaconBlockRoot = Opt.none(Hash32)

    ok(
      Header(
        parentHash: p.parent_hash.asBlockHash,
        ommersHash: EMPTY_UNCLE_HASH,
        coinbase: Address(p.fee_recipient.data),
        stateRoot: p.state_root.asBlockHash,
        transactionsRoot: p.transactions_root.asBlockHash,
        receiptsRoot: p.receipts_root.asBlockHash,
        logsBloom: FixedBytes[BYTES_PER_LOGS_BLOOM](p.logs_bloom.data),
        difficulty: DifficultyInt(0.u256),
        number: BlockNumber(p.block_number),
        gasLimit: GasInt(p.gas_limit),
        gasUsed: GasInt(p.gas_used),
        timestamp: EthTime(p.timestamp),
        extraData: seq[byte](p.extra_data),
        mixHash: p.prev_randao.data.to(Bytes32),
        nonce: default(Bytes8),
        baseFeePerGas: Opt.some(p.base_fee_per_gas),
        withdrawalsRoot: Opt.some(p.withdrawals_root.asBlockHash),
        blobGasUsed: blobGasUsed,
        excessBlobGas: excessBlobGas,
        parentBeaconBlockRoot: parentBeaconBlockRoot,
        requestsHash: Opt.none(Hash32),
      )
    )

proc init*(
    T: type RpcVerificationEngine, config: RpcVerificationEngineConf
): EngineResult[T] =
  randomize()

  let metadata = loadEth2Network(config.eth2Network)

  let
    genesisState =
      try:
        template genesisData(): auto =
          metadata.genesis.bakedBytes

        newClone(
          readSszForkedHashedBeaconState(
            metadata.cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)
          )
        )
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg
    genesisTime = genesisState[].genesis_time
    beaconClock = BeaconClock.init(metadata.cfg.timeParams, genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure
    getBeaconTime = beaconClock.getBeaconTimeFn()
    genesis_validators_root = genesisState[].genesis_validators_root
    forkDigests = newClone ForkDigests.init(metadata.cfg, genesis_validators_root)

  let engine = RpcVerificationEngine(
    chainId: config.chainId,
    timeParams: metadata.cfg.timeParams,
    getBeaconTime: getBeaconTime,
    trustedBlockRoot: some(config.trustedBlockRoot),
    lcStore: (ref ForkedLightClientStore)(),
    maxBlockWalk: config.maxBlockWalk,
    headerStore: HeaderStore.new(config.headerStoreLen),
    accountsCache: AccountsCache.init(config.accountCacheLen),
    codeCache: CodeCache.init(config.codeCacheLen),
    storageCache: StorageCache.init(config.storageCacheLen),
    parallelBlockDownloads: config.parallelBlockDownloads,
    availabilityScoreFunc: defaultAvailabilityScoreFunc,
    qualityScoreFunc: defaultQualityScoreFunc,
    cfg: metadata.cfg,
    forkDigests: forkDigests,
  )

  let networkId = ?chainIdToNetworkId(config.chainId)

  # since AsyncEvm requires a few transport methods (getStorage, getCode etc.)
  # for initialization, we initialize the proxy first then the evm within it
  engine.evm = AsyncEvm.init(engine.toAsyncEvmStateBackend(), networkId)

  proc onStoreInitialized() =
    discard

  proc onFinalizedHeader() =
    withForkyStore(engine.lcStore[]):
      when lcDataFork > LightClientDataFork.Altair:
        info "New LC finalized header",
          finalized_header = shortLog(forkyStore.finalized_header)
        let header = convLCHeader(forkyStore.finalized_header).valueOr:
          error "finalized header conversion error", error = error
          return
        let res = engine.headerStore.updateFinalized(
          header, forkyStore.finalized_header.execution.block_hash.asBlockHash
        )
        if res.isErr():
          error "finalized header update error", error = res.error()
      else:
        error "pre-bellatrix light client headers do not have the execution payload header"

  proc onOptimisticHeader() =
    withForkyStore(engine.lcStore[]):
      when lcDataFork > LightClientDataFork.Altair:
        info "New LC optimistic header",
          optimistic_header = shortLog(forkyStore.optimistic_header)
        let header = convLCHeader(forkyStore.optimistic_header).valueOr:
          error "optimistic header conversion error", error = error
          return
        let res = engine.headerStore.updateFinalized(
          header, forkyStore.optimistic_header.execution.block_hash.asBlockHash
        )
        if res.isErr():
          error "optimistic header update error", error = res.error()
      else:
        error "pre-bellatrix light client headers do not have the execution payload header"

  engine.lcProcessor = LightClientProcessor.new(
    false,
    ".",
    ".",
    metadata.cfg,
    genesis_validators_root,
    LightClientFinalizationMode.Strict,
    engine.lcStore,
    getBeaconTime,
    proc(): Option[Eth2Digest] =
      engine.trustedBlockRoot,
    onStoreInitialized,
    onFinalizedHeader,
    onOptimisticHeader,
  )

  ok(engine)

func isLCStoreInitialized(engine: RpcVerificationEngine): bool =
  engine.lcStore != nil and engine.lcStore[].kind > LightClientDataFork.None

func getLCFinalizedSlot(engine: RpcVerificationEngine): Slot =
  withForkyStore(engine.lcStore[]):
    when lcDataFork > LightClientDataFork.None:
      forkyStore.finalized_header.beacon.slot
    else:
      GENESIS_SLOT

func getLCOptimisticSlot(engine: RpcVerificationEngine): Slot =
  withForkyStore(engine.lcStore[]):
    when lcDataFork > LightClientDataFork.None:
      forkyStore.optimistic_header.beacon.slot
    else:
      GENESIS_SLOT

func isLCNextSyncCommitteeKnown(engine: RpcVerificationEngine): bool =
  withForkyStore(engine.lcStore[]):
    when lcDataFork > LightClientDataFork.None:
      forkyStore.is_next_sync_committee_known
    else:
      false

proc isSynced*(engine: RpcVerificationEngine): bool =
  if engine.getBeaconTime == nil or not engine.isLCStoreInitialized() or
      not engine.isLCNextSyncCommitteeKnown():
    return false

  let current = engine.getBeaconTime().slotOrZero(engine.timeParams)
  # helps with "latest"
  engine.getLCOptimisticSlot() >= current

proc processObject[T: SomeForkedLightClientObject](
    engine: RpcVerificationEngine, obj: T, endpoint: static string
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  let resfut = Future[Result[void, LightClientVerifierError]]
    .Raising([CancelledError])
    .init("lcVerifier")

  engine.lcProcessor[].addObject(MsgSource.gossip, obj, resfut)

  let res = await resfut

  if res.isOk:
    return ok()

  case res.error
  of LightClientVerifierError.MissingParent:
    debug "LC object requires missing parent", endpoint = endpoint
    return err((UnavailableDataError, "missing parent", UNTAGGED))
  of LightClientVerifierError.Duplicate:
    return err((UnavailableDataError, "duplicate", UNTAGGED))
  of LightClientVerifierError.UnviableFork:
    notice "Received LC value from an unviable fork", endpoint = endpoint
    return err((VerificationError, "unviable fork", UNTAGGED))
  of LightClientVerifierError.Invalid:
    warn "Received invalid LC value", endpoint = endpoint
    return err((VerificationError, "invalid LC value", UNTAGGED))

proc syncOnce*(
    engine: RpcVerificationEngine
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  if engine.lcProcessor == nil:
    return err((UnavailableDataError, "beacon not initialized", UNTAGGED))

  if not engine.isLCStoreInitialized():
    if engine.trustedBlockRoot.isNone:
      return err((UnavailableDataError, "trusted block root not set", UNTAGGED))

    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconBootstrap))
      res =
        ?(
          (await backend.getLightClientBootstrap(engine.trustedBlockRoot.get)).tagBackend(
            backendIdx
          )
        )
    ?((await engine.processObject(res, "bootstrap")).tagBackend(backendIdx))

  let
    wallTime = engine.getBeaconTime()
    current = wallTime.slotOrZero(engine.timeParams)
    finalized = engine.getLCFinalizedSlot()
    optimistic = engine.getLCOptimisticSlot()

  # sync committee updates
  if finalized.sync_committee_period == optimistic.sync_committee_period and
      not engine.isLCNextSyncCommitteeKnown():
    let count =
      if finalized.sync_committee_period >= current.sync_committee_period:
        uint64(1)
      else:
        min(
          current.sync_committee_period - finalized.sync_committee_period,
          MAX_REQUEST_LIGHT_CLIENT_UPDATES,
        )

    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconUpdates))
      updRes =
        ?(
          (
            await backend.getLightClientUpdatesByRange(
              finalized.sync_committee_period, count
            )
          ).tagBackend(backendIdx)
        )
      check = distinctBase(updRes).checkLightClientUpdates(
          finalized.sync_committee_period, count
        )

    if check.isErr():
      return err(
        (
          VerificationError,
          "light client updates checking failed: " & check.error,
          backendIdx,
        )
      )

    for update in updRes:
      ?((await engine.processObject(update, "updates")).tagBackend(backendIdx))

  if optimistic < current:
    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconOptimistic))
      optRes =
        ?((await backend.getLightClientOptimisticUpdate()).tagBackend(backendIdx))
    ?((await engine.processObject(optRes, "optimistic")).tagBackend(backendIdx))

  if current.epoch > finalized.epoch + 2:
    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconOptimistic))
      finRes = ?((await backend.getLightClientFinalityUpdate()).tagBackend(backendIdx))
    ?((await engine.processObject(finRes, "finality")).tagBackend(backendIdx))

  return ok()

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
  eth/common/[hashes, headers, addresses, eth_types_rlp],
  web3/eth_api_types,
  beacon_chain/spec/forks,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/beacon_clock,
  beacon_chain/sync/light_client_sync_helpers,
  beacon_chain/networking/network_metadata,
  beacon_chain/el/engine_api_conversions,
  ./types,
  ./utils,
  ./genesis_params,
  ./header_store,
  ./evm

from eth/common/blocks import EMPTY_UNCLE_HASH

logScope:
  topics = "vp_engine"

proc applyPenalty*(engine: RpcVerificationEngine, e: ErrorTuple) =
  if e.backendIdx < 0:
    return
  let idx = e.backendIdx
  try:
    case e.errType
    of BackendFetchError, BackendDecodingError:
      debug "Penalizing backend", backendIdx = idx, errType = $e.errType, err = e.errMsg
      engine.scores[idx].availability =
        engine.availabilityScoreFunc(engine.scores[idx].availability, Penalty)
      engine.scores[idx].quality =
        engine.qualityScoreFunc(engine.scores[idx].quality, UndoReward)
    of VerificationError:
      warn "Backend served data that failed verification",
        backendIdx = idx, err = e.errMsg
      engine.scores[idx].quality =
        engine.qualityScoreFunc(engine.scores[idx].quality, Penalty)
    else:
      discard
  except KeyError:
    debug "Penalty skipped, unknown backend", backendIdx = idx

func convLCHeader*(lcHeader: ForkyLightClientHeader): Result[Header, string] =
  when lcHeader is altair.LightClientHeader:
    err("pre-bellatrix light client headers do not have execution header")
  elif lcHeader is gloas.LightClientHeader:
    err("gloas light client headers do not carry full execution header")
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
        number: base.BlockNumber(p.block_number),
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

proc initCore*(
    T: type RpcVerificationEngine,
    chainId: UInt256,
    networkId: UInt256,
    maxBlockWalk: uint64,
    maxWindowJumps: uint64,
    parallelBlockDownloads: uint64,
    headerStoreLen: int,
    accountCacheLen: int,
    codeCacheLen: int,
    storageCacheLen: int,
): EngineResult[T] =
  randomize()

  let engine = RpcVerificationEngine(
    chainId: chainId,
    maxBlockWalk: maxBlockWalk,
    maxWindowJumps: maxWindowJumps,
    headerStore: HeaderStore.new(headerStoreLen),
    accountsCache: AccountsCache.init(accountCacheLen),
    codeCache: CodeCache.init(codeCacheLen),
    storageCache: StorageCache.init(storageCacheLen),
    parallelBlockDownloads: parallelBlockDownloads,
    availabilityScoreFunc: defaultAvailabilityScoreFunc,
    qualityScoreFunc: defaultQualityScoreFunc,
  )

  # since AsyncEvm requires a few transport methods (getStorage, getCode etc.)
  # for initialization, we initialize the proxy first then the evm within it
  engine.evm = AsyncEvm.init(engine.toAsyncEvmStateBackend(), networkId)

  engine.syncLock = newAsyncLock()

  ok(engine)

proc init*(
    T: type RpcVerificationEngine, config: RpcVerificationEngineConf
): EngineResult[T] =
  let
    networkName = config.eth2Network.get("mainnet")
    metadata = getMetadataForNetwork(networkName)
    genesis = genesisParamsForNetwork(networkName)
    genesisTime = genesis.genesisTime
    genesis_validators_root = genesis.genesisValidatorsRoot
    beaconClock = BeaconClock.init(metadata.cfg.timeParams, genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit QuitFailure
    getBeaconTime =
      if config.freezeAtSlot == Slot(0):
        beaconClock.getBeaconTimeFn()
      else:
        proc(): BeaconTime {.gcsafe, raises: [].} =
          config.freezeAtSlot.start_beacon_time(metadata.cfg.timeParams)
    forkDigests = newClone ForkDigests.init(metadata.cfg, genesis_validators_root)
    networkId = ?chainIdToNetworkId(config.chainId)

  let engine = ?RpcVerificationEngine.initCore(
    chainId = config.chainId,
    networkId = networkId,
    maxBlockWalk = config.maxBlockWalk,
    maxWindowJumps = config.maxWindowJumps,
    parallelBlockDownloads = config.parallelBlockDownloads,
    headerStoreLen = config.headerStoreLen,
    accountCacheLen = config.accountCacheLen,
    codeCacheLen = config.codeCacheLen,
    storageCacheLen = config.storageCacheLen,
  )

  # layer the beacon / light-client fields on top of the core
  engine.timeParams = metadata.cfg.timeParams
  engine.getBeaconTime = getBeaconTime
  engine.trustedBlockRoot = some(config.trustedBlockRoot)
  engine.lcStore = (ref ForkedLightClientStore)()
  engine.maxLightClientUpdates = config.maxLightClientUpdates
  engine.cfg = metadata.cfg
  engine.forkDigests = forkDigests
  engine.eip2935ForkTime = genesis.eip2935ForkTime

  proc onStoreInitialized() =
    discard

  proc onFinalizedHeader() =
    if not config.syncHeaderStore:
      return

    withForkyStore(engine.lcStore[]):
      when lcDataFork > LightClientDataFork.Gloas:
        {.warning: "Please add implementation here for: " & $lcDataFork.}
        error "post-gloas onFinalizedHeader has no implementation"
      elif lcDataFork == LightClientDataFork.Gloas:
        info "New LC finalized header",
          execution_block_hash = forkyStore.finalized_header.execution_block_hash
        engine.headerStore.putHash(
          forkyStore.finalized_header.execution_block_hash.asBlockHash, Finalized
        )
      elif lcDataFork > LightClientDataFork.Altair:
        info "New LC finalized header",
          finalized_header = shortLog(forkyStore.finalized_header)

        engine.headerStore.putHash(
          forkyStore.finalized_header.execution.block_hash.asBlockHash, Finalized
        )
      else:
        error "pre-bellatrix light client headers do not have the execution payload header"

  proc onOptimisticHeader() =
    if not config.syncHeaderStore:
      return
    withForkyStore(engine.lcStore[]):
      when lcDataFork > LightClientDataFork.Gloas:
        {.warning: "Please add implementation here for: " & $lcDataFork.}
        error "post-gloas onOptimisticHeader has no implementation"
      elif lcDataFork == LightClientDataFork.Gloas:
        info "New LC optimistic header",
          execution_block_hash = forkyStore.optimistic_header.execution_block_hash
        engine.headerStore.putHash(
          forkyStore.optimistic_header.execution_block_hash.asBlockHash, Optimistic
        )
      elif lcDataFork > LightClientDataFork.Altair:
        info "New LC optimistic header",
          optimistic_header = shortLog(forkyStore.optimistic_header)

        engine.headerStore.putHash(
          forkyStore.optimistic_header.execution.block_hash.asBlockHash, Optimistic
        )
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
  # getOptimisticSlot rrturns the attested slot of the block which is always one behind
  # the signing slot for sync committees. So we allow some room
  engine.getLCOptimisticSlot() + 1 >= current

proc requireSynced*(engine: RpcVerificationEngine): EngineResult[void] =
  let notSynced = err(
    (
      UnavailableDataError,
      "light client doesn't know the current and next sync committees, sync first",
      UNTAGGED,
    )
  )

  if engine.getBeaconTime == nil or not engine.isLCStoreInitialized() or
      not engine.isLCNextSyncCommitteeKnown():
    return notSynced

  let current = engine.getBeaconTime().slotOrZero(engine.timeParams)
  if engine.getLCFinalizedSlot().sync_committee_period != current.sync_committee_period:
    return notSynced

  ok()

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
    # we don't care about duplicates
    return ok()
  of LightClientVerifierError.UnviableFork:
    notice "Received LC value from an unviable fork", endpoint = endpoint
    return err((VerificationError, "unviable fork", UNTAGGED))
  of LightClientVerifierError.Invalid:
    warn "Received invalid LC value", endpoint = endpoint
    return err((VerificationError, "invalid LC value", UNTAGGED))

func syncInterval*(engine: RpcVerificationEngine): Duration =
  engine.timeParams.SLOT_DURATION

proc syncOnce*(
    engine: RpcVerificationEngine
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  await engine.syncLock.acquire()
  defer:
    try:
      engine.syncLock.release()
    except AsyncLockError:
      discard

  if engine.lcProcessor == nil:
    return err((UnavailableDataError, "beacon not initialized", UNTAGGED))

  if not engine.isLCStoreInitialized():
    if engine.trustedBlockRoot.isNone:
      return err((UnavailableDataError, "trusted block root not set", UNTAGGED))

    debug "LC store not initialized, bootstrapping",
      trustedBlockRoot = engine.trustedBlockRoot.get

    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconBootstrap))
      res = ?(
        (await backend.getLightClientBootstrap(engine.trustedBlockRoot.get)).tagBackend(
          backendIdx
        )
      )
    ?((await engine.processObject(res, "bootstrap")).tagBackend(backendIdx))

    info "LC bootstrap verified", trustedBlockRoot = engine.trustedBlockRoot.get

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
          engine.maxLightClientUpdates,
        )

    debug "Fetching LC updates", period = finalized.sync_committee_period, count

    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconUpdates))
      updRes = ?(
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

  # +1 because optimistic is the attested slot not the signed slot. Signed slot(sync committees)
  # is always after the block has been attestted in  the current slot
  if optimistic + 1 < current:
    debug "Fetching LC optimistic update", optimistic, current

    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconOptimistic))
      optRes =
        ?((await backend.getLightClientOptimisticUpdate()).tagBackend(backendIdx))
    ?((await engine.processObject(optRes, "optimistic")).tagBackend(backendIdx))

  if current.epoch > finalized.epoch + 2:
    debug "Fetching LC finality update", finalized, current

    let
      (backend, backendIdx) = ?(engine.beaconBackendFor(BeaconFinality))
      finRes = ?((await backend.getLightClientFinalityUpdate()).tagBackend(backendIdx))
    ?((await engine.processObject(finRes, "finality")).tagBackend(backendIdx))

  return ok()

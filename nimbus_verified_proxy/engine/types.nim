# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, random, options],
  json_rpc/rpcclient,
  web3/[eth_api, eth_api_types],
  stint,
  minilru,
  chronos,
  beacon_chain/spec/forks,
  beacon_chain/gossip_processing/light_client_processor,
  beacon_chain/beacon_clock,
  ../../execution_chain/evm/async_evm,
  ./header_store

export minilru

const
  MAX_ID_TRIES* = 10
  MAX_FILTERS* = 256

type
  AccountsCacheKey* = (Root, Address)
  AccountsCache* = minilru.LruCache[AccountsCacheKey, Account]

  CodeCacheKey* = (Root, Address)
  CodeCache* = minilru.LruCache[CodeCacheKey, seq[byte]]

  StorageCacheKey* = (Root, Address, UInt256)
  StorageCache* = minilru.LruCache[StorageCacheKey, UInt256]

  BlockTag* = eth_api_types.RtBlockIdentifier

  # All EngineError's are propagated back to the application.
  # Anything that need not be propagated must either be translated
  # or absorbed.
  EngineError* = enum
    # these errors are abstracted to support a simple architecture
    # (encode -> fetch -> decode) that is adaptable for different
    # kinds of backends. These errors help in scoring endpoints too.
    BackendEncodingError
    BackendFetchError
    BackendDecodingError
    BackendError # generic backend error
    FrontendError # generic frontend error

    # besides backend errors the other errors that can occur
    # There is not much use to differentiating these and are done
    # to this extent just for the sake of it.
    UnavailableDataError
    InvalidDataError
    VerificationError

  ErrorTuple* = tuple[errType: EngineError, errMsg: string, backendIdx: int]
  EngineResult*[T] = Result[T, ErrorTuple]

  # every backend get rewarded by default, hence undo reward just removes the
  # default reward (1 - 1 = 0) and penalty negatively scores (1 - 2 = -1)
  ScoreDirection* = enum
    Penalty = -2
    UndoReward = -1
    DefaultReward = 1

  ScoreFunc* = proc(prevScore: int, direction: ScoreDirection): int {.
    noSideEffect, raises: [], gcsafe
  .}

  BackendScore* = object
    availability*: int # penalised on transport errors
    quality*: int # penalised on verification failures

  # Execution API Backend
  ExecutionApiBackend* = object
    eth_chainId*:
      proc(): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).}
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).}
    eth_getCode*: proc(
      address: Address, blockId: BlockTag
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).}
    eth_getBlockReceipts*: proc(
      blockId: BlockTag
    ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getTransactionReceipt*: proc(
      txHash: Hash32
    ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).}
    eth_getTransactionByHash*: proc(
      txHash: Hash32
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).}
    eth_getLogs*: proc(
      filterOptions: FilterOptions
    ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).}
    eth_feeHistory*: proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: seq[int]
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).}
    eth_sendRawTransaction*: proc(txBytes: seq[byte]): Future[EngineResult[Hash32]] {.
      async: (raises: [CancelledError])
    .}

  # Execution API Frontend
  ExecutionApiFrontend* = object # Chain
    eth_chainId*:
      proc(): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).}
    eth_blockNumber*:
      proc(): Future[EngineResult[uint64]] {.async: (raises: [CancelledError]).}

    # State
    eth_getBalance*: proc(
      address: Address, blockId: BlockTag
    ): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).}
    eth_getStorageAt*: proc(
      address: Address, slot: UInt256, blockId: BlockTag
    ): Future[EngineResult[FixedBytes[32]]] {.async: (raises: [CancelledError]).}
    eth_getTransactionCount*: proc(
      address: Address, blockId: BlockTag
    ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_getCode*: proc(
      address: Address, blockId: BlockTag
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).}

    # Block
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getUncleCountByBlockHash*: proc(blkHash: Hash32): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
    .}
    eth_getUncleCountByBlockNumber*: proc(
      blkNum: BlockTag
    ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_getBlockTransactionCountByHash*: proc(
      blkHash: Hash32
    ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_getBlockTransactionCountByNumber*: proc(
      blkNum: BlockTag
    ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}

    # Transaction
    eth_getTransactionByBlockHashAndIndex*: proc(
      blkHash: Hash32, index: Quantity
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).}
    eth_getTransactionByBlockNumberAndIndex*: proc(
      blkNum: BlockTag, index: Quantity
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).}
    eth_getTransactionByHash*: proc(
      txHash: Hash32
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).}

    # EVM
    eth_call*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).}
    eth_estimateGas*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}

    # Receipts
    eth_getBlockReceipts*: proc(
      blockId: BlockTag
    ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getTransactionReceipt*: proc(
      txHash: Hash32
    ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).}
    eth_getLogs*: proc(
      filterOptions: FilterOptions
    ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).}
    eth_newFilter*: proc(filterOptions: FilterOptions): Future[EngineResult[string]] {.
      async: (raises: [CancelledError])
    .}
    eth_uninstallFilter*: proc(filterId: string): Future[EngineResult[bool]] {.
      async: (raises: [CancelledError])
    .}
    eth_getFilterLogs*: proc(filterId: string): Future[EngineResult[seq[LogObject]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getFilterChanges*: proc(filterId: string): Future[EngineResult[seq[LogObject]]] {.
      async: (raises: [CancelledError])
    .}

    # Fee-based
    eth_blobBaseFee*:
      proc(): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).}
    eth_gasPrice*:
      proc(): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_maxPriorityFeePerGas*:
      proc(): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_feeHistory*: proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: seq[int]
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).}
    eth_sendRawTransaction*: proc(txBytes: seq[byte]): Future[EngineResult[Hash32]] {.
      async: (raises: [CancelledError])
    .}

  # Beacon API backend
  LightClientBootstrapProc* = proc(
    blockRoot: Eth2Digest
  ): Future[EngineResult[ForkedLightClientBootstrap]] {.
    async: (raises: [CancelledError])
  .}
  LightClientUpdatesByRangeProc* = proc(
    startPeriod: SyncCommitteePeriod, count: uint64
  ): Future[EngineResult[seq[ForkedLightClientUpdate]]] {.
    async: (raises: [CancelledError])
  .}
  LightClientFinalityUpdateProc* = proc(): Future[
    EngineResult[ForkedLightClientFinalityUpdate]
  ] {.async: (raises: [CancelledError]).}
  LightClientOptimisticUpdateProc* = proc(): Future[
    EngineResult[ForkedLightClientOptimisticUpdate]
  ] {.async: (raises: [CancelledError]).}

  BeaconApiBackend* = object
    getLightClientBootstrap*: LightClientBootstrapProc
    getLightClientUpdatesByRange*: LightClientUpdatesByRangeProc
    getLightClientFinalityUpdate*: LightClientFinalityUpdateProc
    getLightClientOptimisticUpdate*: LightClientOptimisticUpdateProc

  BackendCapability* = enum
    ChainId # eth_chainId
    GetBlockByHash # eth_getBlockByHash
    GetBlockByNumber # eth_getBlockByNumber
    GetProof # eth_getProof
    CreateAccessList # eth_createAccessList
    GetCode # eth_getCode
    GetBlockReceipts # eth_getBlockReceipts
    GetTransactionReceipt # eth_getTransactionReceipt
    GetTransactionByHash # eth_getTransactionByHash
    GetLogs # eth_getLogs
    FeeHistory # eth_feeHistory
    SendRawTransaction # eth_sendRawTransaction
    BeaconBootstrap
    BeaconUpdates
    BeaconFinality
    BeaconOptimistic

  BackendCapabilities* = set[BackendCapability]

  FilterStoreItem* = object
    filter*: FilterOptions
    blockMarker*: Opt[Quantity]

  RpcVerificationEngine* = ref object
    evm*: AsyncEvm

    # chain stores
    headerStore*: HeaderStore
    filterStore*: Table[string, FilterStoreItem]

    # state caches
    accountsCache*: AccountsCache
    codeCache*: CodeCache
    storageCache*: StorageCache

    numBackends: int
    executionBackends: Table[int, ExecutionApiBackend]
    beaconBackends: Table[int, BeaconApiBackend]
    scores*: Table[int, BackendScore]
    capabilityIndex: array[BackendCapability, seq[int]]

    # scoring
    availabilityScoreFunc*: ScoreFunc
    qualityScoreFunc*: ScoreFunc

    lcStore*: ref ForkedLightClientStore
    lcProcessor*: ref LightClientProcessor
    trustedBlockRoot*: Option[Eth2Digest]
    getBeaconTime*: GetBeaconTimeFn
    timeParams*: TimeParams
    syncLock*: AsyncLock

    # beacon metadata (stored for use by beacon backend factories)
    cfg*: RuntimeConfig
    forkDigests*: ref ForkDigests

    # config items
    chainId*: UInt256
    maxBlockWalk*: uint64
    parallelBlockDownloads*: uint64
    maxLightClientUpdates*: uint64

  RpcVerificationEngineConf* = ref object
    chainId*: UInt256
    eth2Network*: Option[string]
    maxBlockWalk*: uint64
    headerStoreLen*: int
    accountCacheLen*: int
    codeCacheLen*: int
    storageCacheLen*: int
    parallelBlockDownloads*: uint64
    maxLightClientUpdates*: uint64
    trustedBlockRoot*: Eth2Digest
    syncHeaderStore*: bool
    freezeAtSlot*: Slot

func eligible*(s: BackendScore): bool =
  s.availability >= 0 and s.quality >= 0

func defaultAvailabilityScoreFunc*(prevScore: int, direction: ScoreDirection): int =
  let newScore = prevScore + ord(direction)

  if newScore < 0:
    return -5 # push it down further
  else:
    min(5, newScore)

func defaultQualityScoreFunc*(prevScore: int, direction: ScoreDirection): int =
  let newScore = prevScore + ord(direction)

  if newScore < 0:
    return -10 # push it down further
  else:
    min(1, newScore)

const UNTAGGED* = -1
  # backendIdx sentinel when error is not attributed to a specific backend
const fullExecutionCapabilities* = BackendCapabilities(
  {
    ChainId, GetBlockByHash, GetBlockByNumber, GetProof, CreateAccessList, GetCode,
    GetBlockReceipts, GetTransactionReceipt, GetTransactionByHash, GetLogs, FeeHistory,
    SendRawTransaction,
  }
)

const fullBeaconCapabilities* = BackendCapabilities(
  {BeaconBootstrap, BeaconUpdates, BeaconFinality, BeaconOptimistic}
)

proc registerBackend*(
    engine: RpcVerificationEngine,
    backend: ExecutionApiBackend,
    capabilities: BackendCapabilities,
) =
  let idx = engine.numBackends
  engine.numBackends += 1
  engine.executionBackends[idx] = backend
  engine.scores[idx] = BackendScore() # availability = 0, quality = 0
  for cap in capabilities:
    engine.capabilityIndex[cap].add(idx)

proc registerBackend*(
    engine: RpcVerificationEngine,
    backend: BeaconApiBackend,
    capabilities: BackendCapabilities,
) =
  let idx = engine.numBackends
  engine.numBackends += 1
  engine.beaconBackends[idx] = backend
  engine.scores[idx] = BackendScore() # availability = 0, quality = 0
  for cap in capabilities:
    engine.capabilityIndex[cap].add(idx)

proc selectBackend(
    engine: RpcVerificationEngine, cap: BackendCapability
): EngineResult[int] =
  # Decay excluded backends toward 0 so they can recover over time
  for s in engine.scores.mvalues:
    if s.availability < 0:
      inc s.availability
    if s.quality < 0:
      inc s.quality

  var eligibleIdxs: seq[int]
  for b in engine.capabilityIndex[cap]:
    try:
      if engine.scores[b].eligible():
        eligibleIdxs.add(b)
    except KeyError:
      return err(
        (
          BackendError, "Backend registered for capability not found in scores",
          UNTAGGED,
        )
      )

  if eligibleIdxs.len == 0:
    return err((BackendError, "No eligible backend for capability: " & $cap, UNTAGGED))

  # randomly select a backend from eligible backends
  let chosen = eligibleIdxs[rand(eligibleIdxs.len - 1)]

  # add a default reward
  try:
    engine.scores[chosen].availability =
      engine.availabilityScoreFunc(engine.scores[chosen].availability, DefaultReward)
    engine.scores[chosen].quality =
      engine.qualityScoreFunc(engine.scores[chosen].quality, DefaultReward)
  except KeyError:
    return err((BackendError, "Scores not found for the chosen backend", UNTAGGED))

  ok(chosen)

proc executionBackendFor*(
    engine: RpcVerificationEngine, cap: BackendCapability
): EngineResult[(ExecutionApiBackend, int)] =
  let chosen = ?engine.selectBackend(cap)

  try:
    ok((engine.executionBackends[chosen], chosen))
  except KeyError:
    err((BackendError, "Chosen backend not found", UNTAGGED))

proc beaconBackendFor*(
    engine: RpcVerificationEngine, cap: BackendCapability
): EngineResult[(BeaconApiBackend, int)] =
  let chosen = ?engine.selectBackend(cap)

  try:
    ok((engine.beaconBackends[chosen], chosen))
  except KeyError:
    err((BackendError, "Chosen backend not found", UNTAGGED))

template tagBackend*[T](r: EngineResult[T], idx: int): EngineResult[T] =
  block:
    let taggedR: EngineResult[T] = r
    if taggedR.isErr():
      let e = taggedR.error
      # if the error is not tagged then tag it
      if e.backendIdx < 0:
        Result[T, ErrorTuple].err((e.errType, e.errMsg, idx))
      else:
        taggedR
    else:
      taggedR

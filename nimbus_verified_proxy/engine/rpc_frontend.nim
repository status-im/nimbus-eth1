# nimbus_verified_proxy
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  results,
  stew/byteutils,
  nimcrypto/sysrand,
  json_rpc/[rpcserver, rpcclient],
  eth/common/accounts,
  web3/[eth_api, eth_api_types],
  ../../execution_chain/core/eip4844,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/common/common,
  ./types,
  ./header_store,
  ./accounts,
  ./blocks,
  ./evm,
  ./transactions,
  ./receipts,
  ./fees

# Most of the light client is already tested and hence removed from the testing
# process here. Also because it is significantly more complex to mock a beacon
# light client than to just mute it during tests.
when not defined(nimbus_verified_proxy_testing):
  import ./engine

template beaconSync(engine: RpcVerificationEngine) =
  when not defined(nimbus_verified_proxy_testing):
    ?(await engine.syncOnce())

proc applyPenalty(engine: RpcVerificationEngine, e: ErrorTuple) =
  if e.backendIdx < 0:
    return
  let idx = e.backendIdx
  try:
    case e.errType
    of BackendFetchError, BackendDecodingError:
      engine.scores[idx].availability =
        engine.availabilityScoreFunc(engine.scores[idx].availability, Penalty)
      engine.scores[idx].quality =
        engine.qualityScoreFunc(engine.scores[idx].quality, UndoReward)
    of VerificationError:
      engine.scores[idx].quality =
        engine.qualityScoreFunc(engine.scores[idx].quality, Penalty)
    else:
      discard
  except KeyError:
    discard

template penaltyOr[T](engine: RpcVerificationEngine, r: EngineResult[T]): T =
  # `result = ...; return` pattern for chronos async compatibility
  # see https://github.com/status-im/nim-stew/issues/37
  let penaltyOrResult: EngineResult[T] = r
  if penaltyOrResult.isErr():
    engine.applyPenalty(penaltyOrResult.error)
    result = err(typeof(result), penaltyOrResult.error)
    return
  penaltyOrResult.unsafeGet()

proc registerDefaultFrontend*(engine: RpcVerificationEngine) =
  engine.frontend.eth_chainId = proc(): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
  .} =
    ok(engine.chainId)

  engine.frontend.eth_blockNumber = proc(): Future[EngineResult[uint64]] {.
      async: (raises: [CancelledError])
  .} =
    engine.beaconSync()

    # Returns the number of the most recent block.
    let latest = engine.headerStore.latest.valueOr:
      # untagged(-1) because the error cannot be linked to any backend
      return err(
        (
          UnavailableDataError, "Couldn't get the latest header, still syncing?",
          UNTAGGED,
        )
      )

    ok(latest.number.uint64)

  engine.frontend.eth_getBalance = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let header = engine.penaltyOr(await engine.getHeader(quantityTag))
    let account = engine.penaltyOr(
      await engine.getAccount(address, header.number, header.stateRoot)
    )
    ok(account.balance)

  engine.frontend.eth_getStorageAt = proc(
      address: Address, slot: UInt256, quantityTag: BlockTag
  ): Future[EngineResult[FixedBytes[32]]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let header = engine.penaltyOr(await engine.getHeader(quantityTag))
    let storage = engine.penaltyOr(
      await engine.getStorageAt(address, slot, header.number, header.stateRoot)
    )
    ok(storage.to(Bytes32))

  engine.frontend.eth_getTransactionCount = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let header = engine.penaltyOr(await engine.getHeader(quantityTag))
    let account = engine.penaltyOr(
      await engine.getAccount(address, header.number, header.stateRoot)
    )
    ok(Quantity(account.nonce))

  engine.frontend.eth_getCode = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let header = engine.penaltyOr(await engine.getHeader(quantityTag))
    let code =
      engine.penaltyOr(await engine.getCode(address, header.number, header.stateRoot))
    ok(code)

  engine.frontend.eth_getBlockByHash = proc(
      blockHash: Hash32, fullTransactions: bool
  ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockHash, fullTransactions))
    ok(blk)

  engine.frontend.eth_getBlockByNumber = proc(
      blockTag: BlockTag, fullTransactions: bool
  ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockTag, fullTransactions))
    ok(blk)

  engine.frontend.eth_getUncleCountByBlockNumber = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockTag, false))
    ok(Quantity(blk.uncles.len()))

  engine.frontend.eth_getUncleCountByBlockHash = proc(
      blockHash: Hash32
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockHash, false))
    ok(Quantity(blk.uncles.len()))

  engine.frontend.eth_getBlockTransactionCountByNumber = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockTag, true))
    ok(Quantity(blk.transactions.len))

  engine.frontend.eth_getBlockTransactionCountByHash = proc(
      blockHash: Hash32
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockHash, true))
    ok(Quantity(blk.transactions.len))

  engine.frontend.eth_getTransactionByBlockNumberAndIndex = proc(
      blockTag: BlockTag, index: Quantity
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockTag, true))

    if distinctBase(index) >= uint64(blk.transactions.len):
      return
        err((FrontendError, "provided transaction index is outside bounds", UNTAGGED))

    let x = blk.transactions[distinctBase(index)]

    ok(x.tx)

  engine.frontend.eth_getTransactionByBlockHashAndIndex = proc(
      blockHash: Hash32, index: Quantity
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let blk = engine.penaltyOr(await engine.getBlock(blockHash, true))

    if distinctBase(index) >= uint64(blk.transactions.len):
      return
        err((FrontendError, "provided transaction index is outside bounds", UNTAGGED))

    let x = blk.transactions[distinctBase(index)]

    ok(x.tx)

  engine.frontend.eth_call = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    if tx.to.isNone():
      return err((FrontendError, "to address is required", UNTAGGED))

    let header = engine.penaltyOr(await engine.getHeader(blockTag))

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    engine.penaltyOr(
      await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)
    )

    let callResult = (await engine.evm.call(header, tx, optimisticStateFetch)).valueOr:
      # NOTE: untagged(-1) because this error cannot be linked to one specific backend
      # and we cannot downscore every backend. Hence invalid data
      return err((VerificationError, "contract call failed -> " & error, UNTAGGED))

    if callResult.error.len() > 0:
      # NOTE: untagged(-1) because this error cannot be linked to one specific backend
      # and we cannot downscore every backend. Hence invalid data
      return err((VerificationError, callResult.error, UNTAGGED))

    ok(callResult.output)

  engine.frontend.eth_createAccessList = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    if tx.to.isNone():
      return err((FrontendError, "to address is required", UNTAGGED))

    let header = engine.penaltyOr(await engine.getHeader(blockTag))

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    engine.penaltyOr(
      await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)
    )

    let (accessList, error, gasUsed) = (
      await engine.evm.createAccessList(header, tx, optimisticStateFetch)
    ).valueOr:
      # NOTE: untagged(-1) because this error cannot be linked to one specific backend
      # and we cannot downscore every backend. Hence invalid data
      return
        err((VerificationError, "access list calculation failed -> " & error, UNTAGGED))

    ok(
      AccessListResult(accessList: accessList, error: error, gasUsed: gasUsed.Quantity)
    )

  engine.frontend.eth_estimateGas = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    if tx.to.isNone():
      return err((FrontendError, "to address is required", UNTAGGED))

    let header = engine.penaltyOr(await engine.getHeader(blockTag))

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    engine.penaltyOr(
      await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)
    )

    let gasEstimate = (await engine.evm.estimateGas(header, tx, optimisticStateFetch)).valueOr:
      # NOTE: untagged(-1) because this error cannot be linked to one specific backend
      # and we cannot downscore every backend. Hence invalid data
      return err(
        (VerificationError, "gas estimation calculation failed -> " & error, UNTAGGED)
      )

    ok(Quantity(gasEstimate))

  engine.frontend.eth_getTransactionByHash = proc(
      txHash: Hash32
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let (backend, backendIdx) = ?(engine.executionBackendFor(GetTransactionByHash))
    let tx = engine.penaltyOr(
      (await backend.eth_getTransactionByHash(txHash)).tagBackend(backendIdx)
    )

    if tx.hash != txHash:
      return err(
        (
          VerificationError,
          "the downloaded transaction hash doesn't match the requested transaction hash",
          backendIdx,
        )
      )

    if not checkTxHash(tx, txHash):
      return err(
        (
          VerificationError, "the transaction doesn't hash to the provided hash",
          backendIdx,
        )
      )

    ok(tx)

  engine.frontend.eth_getBlockReceipts = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let rxs = engine.penaltyOr(await engine.getReceipts(blockTag))
    ok(Opt.some(rxs))

  engine.frontend.eth_getTransactionReceipt = proc(
      txHash: Hash32
  ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let (backend, backendIdx) = ?(engine.executionBackendFor(GetTransactionReceipt))
    let rx = engine.penaltyOr(
      (await backend.eth_getTransactionReceipt(txHash)).tagBackend(backendIdx)
    )
    let rxs = engine.penaltyOr(await engine.getReceipts(rx.blockHash))

    for r in rxs:
      if r.transactionHash == txHash:
        return ok(r)

    return err((VerificationError, "receipt couldn't be verified", backendIdx))

  engine.frontend.eth_getLogs = proc(
      filterOptions: FilterOptions
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let logObjs = engine.penaltyOr(await engine.getLogs(filterOptions))
    ok(logObjs)

  engine.frontend.eth_newFilter = proc(
      filterOptions: FilterOptions
  ): Future[EngineResult[string]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    if engine.filterStore.len >= MAX_FILTERS:
      return err((UnavailableDataError, "FilterStore already full", UNTAGGED))

    var
      id: array[8, byte] # 64bits
      strId: string

    for i in 0 .. (MAX_ID_TRIES + 1):
      if randomBytes(id) != len(id):
        return err(
          (
            UnavailableDataError,
            "Couldn't generate a random identifier for the filter", UNTAGGED,
          )
        )

      strId = toHex(id)

      if not engine.filterStore.contains(strId):
        break

      if i >= MAX_ID_TRIES:
        return err(
          (
            UnavailableDataError, "Couldn't create a unique identifier for the filter",
            UNTAGGED,
          )
        )

    engine.filterStore[strId] =
      FilterStoreItem(filter: filterOptions, blockMarker: Opt.none(Quantity))

    ok(strId)

  engine.frontend.eth_uninstallFilter = proc(
      filterId: string
  ): Future[EngineResult[bool]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    if filterId in engine.filterStore:
      engine.filterStore.del(filterId)
      return ok(true)

    ok(false)

  engine.frontend.eth_getFilterLogs = proc(
      filterId: string
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    try:
      let logObjs =
        engine.penaltyOr(await engine.getLogs(engine.filterStore[filterId].filter))
      ok(logObjs)
    except KeyError as e:
      err((FrontendError, "Filter doesn't exist", UNTAGGED))

  engine.frontend.eth_getFilterChanges = proc(
      filterId: string
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let filterItem =
      try:
        engine.filterStore[filterId]
      except KeyError as e:
        return err((FrontendError, "Filter doesn't exist", UNTAGGED))

    let
      filter = ?engine.resolveFilterTags(filterItem.filter)
      # after resolving toBlock is always some and a number tag
      toBlock = filter.toBlock.get().number

    if filterItem.blockMarker.isSome() and toBlock <= filterItem.blockMarker.get():
      return err(
        (
          UnavailableDataError, "No changes for the filter since the last query",
          UNTAGGED,
        )
      )

    let
      fromBlock =
        if filterItem.blockMarker.isSome():
          Opt.some(
            types.BlockTag(kind: bidNumber, number: filterItem.blockMarker.get())
          )
        else:
          filter.fromBlock

      changesFilter = FilterOptions(
        fromBlock: fromBlock,
        toBlock: filter.toBlock,
        address: filter.address,
        topics: filter.topics,
        blockHash: filter.blockHash,
      )
    let logObjs = engine.penaltyOr(await engine.getLogs(changesFilter))

    # all logs verified so we can update blockMarker
    try:
      engine.filterStore[filterId].blockMarker = Opt.some(toBlock)
    except KeyError as e:
      return err((FrontendError, "Filter doesn't exist", UNTAGGED))

    ok(logObjs)

  engine.frontend.eth_blobBaseFee = proc(): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
  .} =
    engine.beaconSync()

    let com = CommonRef.new(
      DefaultDbMemory.newCoreDbRef(),
      config = chainConfigForNetwork(engine.chainId),
      initializeDb = false,
      statelessProviderEnabled = true, # Enables collection of witness keys
    )

    let header = engine.penaltyOr(await engine.getHeader(blockId("latest")))

    if header.blobGasUsed.isNone():
      return
        err((UnavailableDataError, "blobGasUsed missing from latest header", UNTAGGED))
    if header.excessBlobGas.isNone():
      return err(
        (UnavailableDataError, "excessBlobGas missing from latest header", UNTAGGED)
      )
    let blobBaseFee =
      getBlobBaseFee(header.excessBlobGas.get, com, com.toEVMFork(header)) *
      header.blobGasUsed.get.u256

    ok(blobBaseFee)

  engine.frontend.eth_gasPrice = proc(): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
  .} =
    engine.beaconSync()

    let suggestedPrice = engine.penaltyOr(await engine.suggestGasPrice())
    ok(Quantity(suggestedPrice.uint64))

  engine.frontend.eth_maxPriorityFeePerGas = proc(): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
  .} =
    engine.beaconSync()

    let suggestedPrice = engine.penaltyOr(await engine.suggestMaxPriorityGasPrice())
    ok(Quantity(suggestedPrice.uint64))

  # pass-forward
  engine.frontend.eth_getProof = proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
  ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let (backend, backendIdx) = ?(engine.executionBackendFor(GetProof))
    let proof = engine.penaltyOr(
      (await backend.eth_getProof(address, slots, blockId)).tagBackend(backendIdx)
    )
    ok(proof)

  engine.frontend.eth_feeHistory = proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: seq[int]
  ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let (backend, backendIdx) = ?(engine.executionBackendFor(FeeHistory))
    let feeHistory = engine.penaltyOr(
      (await backend.eth_feeHistory(blockCount, newestBlock, rewardPercentiles)).tagBackend(
        backendIdx
      )
    )
    ok(feeHistory)

  engine.frontend.eth_sendRawTransaction = proc(
      txBytes: seq[byte]
  ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
    engine.beaconSync()

    let (backend, backendIdx) = ?(engine.executionBackendFor(SendRawTransaction))
    let txHash = engine.penaltyOr(
      (await backend.eth_sendRawTransaction(txBytes)).tagBackend(backendIdx)
    )
    ok(txHash)

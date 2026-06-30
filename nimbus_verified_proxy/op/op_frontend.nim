# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/strutils,
  results,
  stew/byteutils,
  nimcrypto/sysrand,
  json_rpc/[rpcserver, rpcclient],
  eth/common/accounts,
  web3/[eth_api, eth_api_types],
  ../../execution_chain/core/eip4844,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/common/common,
  ../engine/types,
  ../engine/header_store,
  ../engine/accounts,
  ../engine/blocks,
  ../engine/evm,
  ../engine/transactions,
  ../engine/receipts,
  ../engine/fees,
  ./op_anchor,
  ./op_chain_params

template opSync(opEngine: RpcVerificationEngine, l1Engine: RpcVerificationEngine) =
  block:
    await opEngine.syncLock.acquire()

    defer:
      try:
        opEngine.syncLock.release()
      except AsyncLockError:
        # FIXME: is this dangerous?
        discard

    ?(await opEngine.opSyncOnce(l1Engine))

template penaltyOr[T](engine: RpcVerificationEngine, r: EngineResult[T]): T =
  let penaltyOrResult: EngineResult[T] = r
  if penaltyOrResult.isErr():
    engine.applyPenalty(penaltyOrResult.error)
    result = err(typeof(result), penaltyOrResult.error)
    return
  penaltyOrResult.unsafeGet()

proc resolveOpTag(
    opEngine: RpcVerificationEngine, blockTag: BlockTag
): Future[EngineResult[BlockTag]] {.async: (raises: [CancelledError]).} =
  if blockTag.kind != bidAlias:
    return ok(blockTag)

  case blockTag.alias.toLowerAscii()
  of "latest", "pending":
    let tip = ?(await opEngine.resolveUnsafeTip())
    ok(BlockTag(kind: bidNumber, number: Quantity(tip.number)))
  of "safe":
    let h = opEngine.headerStore.latest().valueOr:
      return err((UnavailableDataError, "no safe L2 header yet", UNTAGGED))
    ok(BlockTag(kind: bidNumber, number: Quantity(h.number)))
  of "finalized":
    let h = opEngine.headerStore.finalized().valueOr:
      return err((UnavailableDataError, "no finalized L2 header yet", UNTAGGED))
    ok(BlockTag(kind: bidNumber, number: Quantity(h.number)))
  of "earliest":
    let h = opEngine.headerStore.earliest().valueOr:
      return err((UnavailableDataError, "no earliest L2 header yet", UNTAGGED))
    ok(BlockTag(kind: bidNumber, number: Quantity(h.number)))
  else:
    err((InvalidDataError, "unsupported block tag " & $blockTag, UNTAGGED))

proc getExecutionApiFrontend*(
    opEngine: RpcVerificationEngine, l1Engine: RpcVerificationEngine
): ExecutionApiFrontend =
  var frontend: ExecutionApiFrontend

  frontend.eth_chainId = proc(): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
  .} =
    ok(opEngine.chainId)

  frontend.eth_blockNumber = proc(): Future[EngineResult[uint64]] {.
      async: (raises: [CancelledError])
  .} =
    opEngine.opSync(l1Engine)

    let latest = opEngine.penaltyOr(await opEngine.resolveUnsafeTip())
    ok(latest.number.uint64)

  frontend.eth_getBalance = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(quantityTag))
    let header = opEngine.penaltyOr(await opEngine.getHeader(tag))
    let account = opEngine.penaltyOr(
      await opEngine.getAccount(address, header.number, header.stateRoot)
    )
    ok(account.balance)

  frontend.eth_getStorageAt = proc(
      address: Address, slot: UInt256, quantityTag: BlockTag
  ): Future[EngineResult[FixedBytes[32]]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(quantityTag))
    let header = opEngine.penaltyOr(await opEngine.getHeader(tag))
    let storage = opEngine.penaltyOr(
      await opEngine.getStorageAt(address, slot, header.number, header.stateRoot)
    )
    ok(storage.to(Bytes32))

  frontend.eth_getTransactionCount = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(quantityTag))
    let header = opEngine.penaltyOr(await opEngine.getHeader(tag))
    let account = opEngine.penaltyOr(
      await opEngine.getAccount(address, header.number, header.stateRoot)
    )
    ok(Quantity(account.nonce))

  frontend.eth_getCode = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(quantityTag))
    let header = opEngine.penaltyOr(await opEngine.getHeader(tag))
    let code = opEngine.penaltyOr(
      await opEngine.getCode(address, header.number, header.stateRoot)
    )
    ok(code)

  frontend.eth_getBlockByHash = proc(
      blockHash: Hash32, fullTransactions: bool
  ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let blk = opEngine.penaltyOr(await opEngine.getBlock(blockHash, fullTransactions))
    ok(blk)

  frontend.eth_getBlockByNumber = proc(
      blockTag: BlockTag, fullTransactions: bool
  ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let blk = opEngine.penaltyOr(await opEngine.getBlock(tag, fullTransactions))
    ok(blk)

  frontend.eth_getUncleCountByBlockNumber = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let blk = opEngine.penaltyOr(await opEngine.getBlock(tag, false))
    ok(Quantity(blk.uncles.len()))

  frontend.eth_getUncleCountByBlockHash = proc(
      blockHash: Hash32
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let blk = opEngine.penaltyOr(await opEngine.getBlock(blockHash, false))
    ok(Quantity(blk.uncles.len()))

  frontend.eth_getBlockTransactionCountByNumber = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let blk = opEngine.penaltyOr(await opEngine.getBlock(tag, true))
    ok(Quantity(blk.transactions.len))

  frontend.eth_getBlockTransactionCountByHash = proc(
      blockHash: Hash32
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let blk = opEngine.penaltyOr(await opEngine.getBlock(blockHash, true))
    ok(Quantity(blk.transactions.len))

  frontend.eth_getTransactionByBlockNumberAndIndex = proc(
      blockTag: BlockTag, index: Quantity
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let blk = opEngine.penaltyOr(await opEngine.getBlock(tag, true))

    if distinctBase(index) >= uint64(blk.transactions.len):
      return
        err((FrontendError, "provided transaction index is outside bounds", UNTAGGED))

    let x = blk.transactions[distinctBase(index)]
    ok(x.tx)

  frontend.eth_getTransactionByBlockHashAndIndex = proc(
      blockHash: Hash32, index: Quantity
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let blk = opEngine.penaltyOr(await opEngine.getBlock(blockHash, true))

    if distinctBase(index) >= uint64(blk.transactions.len):
      return
        err((FrontendError, "provided transaction index is outside bounds", UNTAGGED))

    let x = blk.transactions[distinctBase(index)]
    ok(x.tx)

  frontend.eth_call = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    if tx.to.isNone():
      return err((FrontendError, "to address is required", UNTAGGED))

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let header = opEngine.penaltyOr(await opEngine.getHeader(tag))

    # Start fetching code to get it in the code cache
    discard opEngine.getCode(tx.to.get(), header.number, header.stateRoot)

    opEngine.penaltyOr(
      await opEngine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)
    )

    let callResult = (await opEngine.evm.call(header, tx, optimisticStateFetch)).valueOr:
      return err((VerificationError, "contract call failed -> " & error, UNTAGGED))

    if callResult.error.len() > 0:
      return err((VerificationError, callResult.error, UNTAGGED))

    ok(callResult.output)

  frontend.eth_createAccessList = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    if tx.to.isNone():
      return err((FrontendError, "to address is required", UNTAGGED))

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let header = opEngine.penaltyOr(await opEngine.getHeader(tag))

    discard opEngine.getCode(tx.to.get(), header.number, header.stateRoot)

    opEngine.penaltyOr(
      await opEngine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)
    )

    let (accessList, error, gasUsed) = (
      await opEngine.evm.createAccessList(header, tx, optimisticStateFetch)
    ).valueOr:
      return
        err((VerificationError, "access list calculation failed -> " & error, UNTAGGED))

    ok(
      AccessListResult(accessList: accessList, error: error, gasUsed: gasUsed.Quantity)
    )

  frontend.eth_estimateGas = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    if tx.to.isNone():
      return err((FrontendError, "to address is required", UNTAGGED))

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let header = opEngine.penaltyOr(await opEngine.getHeader(tag))

    discard opEngine.getCode(tx.to.get(), header.number, header.stateRoot)

    opEngine.penaltyOr(
      await opEngine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)
    )

    let gasEstimate = (await opEngine.evm.estimateGas(header, tx, optimisticStateFetch)).valueOr:
      return err(
        (VerificationError, "gas estimation calculation failed -> " & error, UNTAGGED)
      )

    ok(Quantity(gasEstimate))

  frontend.eth_getTransactionByHash = proc(
      txHash: Hash32
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let (backend, backendIdx) = ?(opEngine.executionBackendFor(GetTransactionByHash))
    let tx = opEngine.penaltyOr(
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

  frontend.eth_getBlockReceipts = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockTag))
    let rxs = opEngine.penaltyOr(await opEngine.getReceipts(tag))
    ok(Opt.some(rxs))

  frontend.eth_getTransactionReceipt = proc(
      txHash: Hash32
  ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let (backend, backendIdx) = ?(opEngine.executionBackendFor(GetTransactionReceipt))
    let rx = opEngine.penaltyOr(
      (await backend.eth_getTransactionReceipt(txHash)).tagBackend(backendIdx)
    )
    let rxs = opEngine.penaltyOr(await opEngine.getReceipts(rx.blockHash))

    for r in rxs:
      if r.transactionHash == txHash:
        return ok(r)

    return err((VerificationError, "receipt couldn't be verified", backendIdx))

  frontend.eth_getLogs = proc(
      filterOptions: FilterOptions
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let logObjs = opEngine.penaltyOr(await opEngine.getLogs(filterOptions))
    ok(logObjs)

  frontend.eth_newFilter = proc(
      filterOptions: FilterOptions
  ): Future[EngineResult[string]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    if opEngine.filterStore.len >= MAX_FILTERS:
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

      if not opEngine.filterStore.contains(strId):
        break

      if i >= MAX_ID_TRIES:
        return err(
          (
            UnavailableDataError, "Couldn't create a unique identifier for the filter",
            UNTAGGED,
          )
        )

    opEngine.filterStore[strId] =
      FilterStoreItem(filter: filterOptions, blockMarker: Opt.none(Quantity))

    ok(strId)

  frontend.eth_uninstallFilter = proc(
      filterId: string
  ): Future[EngineResult[bool]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    if filterId in opEngine.filterStore:
      opEngine.filterStore.del(filterId)
      return ok(true)

    ok(false)

  frontend.eth_getFilterLogs = proc(
      filterId: string
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    try:
      let logObjs = opEngine.penaltyOr(
        await opEngine.getLogs(opEngine.filterStore[filterId].filter)
      )
      ok(logObjs)
    except KeyError:
      err((FrontendError, "Filter doesn't exist", UNTAGGED))

  frontend.eth_getFilterChanges = proc(
      filterId: string
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let filterItem =
      try:
        opEngine.filterStore[filterId]
      except KeyError:
        return err((FrontendError, "Filter doesn't exist", UNTAGGED))

    let
      filter = ?opEngine.resolveFilterTags(filterItem.filter)
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
    let logObjs = opEngine.penaltyOr(await opEngine.getLogs(changesFilter))

    try:
      opEngine.filterStore[filterId].blockMarker = Opt.some(toBlock)
    except KeyError:
      return err((FrontendError, "Filter doesn't exist", UNTAGGED))

    ok(logObjs)

  frontend.eth_blobBaseFee = proc(): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
  .} =
    opEngine.opSync(l1Engine)

    let db = DefaultDbMemory.newCoreDbRef()
    defer:
      db.close()

    # the L2 follows the L1 fork schedule, so configure the common with the L1 chain id
    let l1ChainId = opL1ChainId(opEngine.chainId).valueOr:
      return err((InvalidDataError, "unknown op chainId: " & error, UNTAGGED))
    let com = CommonRef.new(
      db,
      config = chainConfigForNetwork(l1ChainId),
      initializeDb = false,
      statelessProviderEnabled = true,
    )

    let header = opEngine.penaltyOr(await opEngine.getHeader(blockId("latest")))

    if header.blobGasUsed.isNone():
      return
        err((UnavailableDataError, "blobGasUsed missing from latest header", UNTAGGED))
    if header.excessBlobGas.isNone():
      return err(
        (UnavailableDataError, "excessBlobGas missing from latest header", UNTAGGED)
      )
    let blobBaseFee =
      getBlobBaseFee(header.excessBlobGas.get, com, com.toHardFork(header)) *
      header.blobGasUsed.get.u256

    ok(blobBaseFee)

  frontend.eth_gasPrice = proc(): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
  .} =
    opEngine.opSync(l1Engine)

    let suggestedPrice = opEngine.penaltyOr(await opEngine.suggestGasPrice())
    ok(Quantity(suggestedPrice))

  frontend.eth_maxPriorityFeePerGas = proc(): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
  .} =
    opEngine.opSync(l1Engine)

    let suggestedPrice = opEngine.penaltyOr(await opEngine.suggestMaxPriorityGasPrice())
    ok(Quantity(suggestedPrice))

  # pass-forward
  frontend.eth_getProof = proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
  ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(blockId))
    let (backend, backendIdx) = ?(opEngine.executionBackendFor(GetProof))
    let proof = opEngine.penaltyOr(
      (await backend.eth_getProof(address, slots, tag)).tagBackend(backendIdx)
    )
    ok(proof)

  frontend.eth_feeHistory = proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: seq[int]
  ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let tag = opEngine.penaltyOr(await opEngine.resolveOpTag(newestBlock))
    let (backend, backendIdx) = ?(opEngine.executionBackendFor(FeeHistory))
    let feeHistory = opEngine.penaltyOr(
      (await backend.eth_feeHistory(blockCount, tag, rewardPercentiles)).tagBackend(
        backendIdx
      )
    )
    ok(feeHistory)

  frontend.eth_sendRawTransaction = proc(
      txBytes: seq[byte]
  ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
    opEngine.opSync(l1Engine)

    let (backend, backendIdx) = ?(opEngine.executionBackendFor(SendRawTransaction))
    let txHash = opEngine.penaltyOr(
      (await backend.eth_sendRawTransaction(txBytes)).tagBackend(backendIdx)
    )
    ok(txHash)

  frontend

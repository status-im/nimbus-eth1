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
  ../../execution_chain/common/common,
  ./types,
  ./header_store,
  ./accounts,
  ./blocks,
  ./evm,
  ./transactions,
  ./receipts,
  ./fees

proc registerDefaultFrontend*(engine: RpcVerificationEngine) =
  engine.frontend.eth_chainId = proc(): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
  .} =
    ok(engine.chainId)

  engine.frontend.eth_blockNumber = proc(): Future[EngineResult[uint64]] {.
      async: (raises: [CancelledError])
  .} =
    ## Returns the number of the most recent block.
    let latest = engine.headerStore.latest.valueOr:
      return err((UnavailableDataError, "Syncing"))

    ok(latest.number.uint64)

  engine.frontend.eth_getBalance = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).} =
    let
      header = ?(await engine.getHeader(quantityTag))
      account = ?(await engine.getAccount(address, header.number, header.stateRoot))

    ok(account.balance)

  engine.frontend.eth_getStorageAt = proc(
      address: Address, slot: UInt256, quantityTag: BlockTag
  ): Future[EngineResult[FixedBytes[32]]] {.async: (raises: [CancelledError]).} =
    let
      header = ?(await engine.getHeader(quantityTag))
      storage =
        ?(await engine.getStorageAt(address, slot, header.number, header.stateRoot))

    ok(storage.to(Bytes32))

  engine.frontend.eth_getTransactionCount = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    let
      header = ?(await engine.getHeader(quantityTag))
      account = ?(await engine.getAccount(address, header.number, header.stateRoot))

    ok(Quantity(account.nonce))

  engine.frontend.eth_getCode = proc(
      address: Address, quantityTag: BlockTag
  ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
    let header = ?(await engine.getHeader(quantityTag))
    await engine.getCode(address, header.number, header.stateRoot)

  engine.frontend.eth_getBlockByHash = proc(
      blockHash: Hash32, fullTransactions: bool
  ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
    await engine.getBlock(blockHash, fullTransactions)

  engine.frontend.eth_getBlockByNumber = proc(
      blockTag: BlockTag, fullTransactions: bool
  ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
    await engine.getBlock(blockTag, fullTransactions)

  engine.frontend.eth_getUncleCountByBlockNumber = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    let blk = ?(await engine.getBlock(blockTag, false))

    ok(Quantity(blk.uncles.len()))

  engine.frontend.eth_getUncleCountByBlockHash = proc(
      blockHash: Hash32
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    let blk = ?(await engine.getBlock(blockHash, false))

    ok(Quantity(blk.uncles.len()))

  engine.frontend.eth_getBlockTransactionCountByNumber = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    let blk = ?(await engine.getBlock(blockTag, true))

    ok(Quantity(blk.transactions.len))

  engine.frontend.eth_getBlockTransactionCountByHash = proc(
      blockHash: Hash32
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    let blk = ?(await engine.getBlock(blockHash, true))

    ok(Quantity(blk.transactions.len))

  engine.frontend.eth_getTransactionByBlockNumberAndIndex = proc(
      blockTag: BlockTag, index: Quantity
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    let blk = ?(await engine.getBlock(blockTag, true))

    if distinctBase(index) >= uint64(blk.transactions.len):
      return err((InvalidDataError, "provided transaction index is outside bounds"))

    let x = blk.transactions[distinctBase(index)]

    doAssert x.kind == tohTx

    ok(x.tx)

  engine.frontend.eth_getTransactionByBlockHashAndIndex = proc(
      blockHash: Hash32, index: Quantity
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    let blk = ?(await engine.getBlock(blockHash, true))

    if distinctBase(index) >= uint64(blk.transactions.len):
      return err((InvalidDataError, "provided transaction index is outside bounds"))

    let x = blk.transactions[distinctBase(index)]

    doAssert x.kind == tohTx

    ok(x.tx)

  engine.frontend.eth_call = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
    if tx.to.isNone():
      return err((InvalidDataError, "to address is required"))

    let header = ?(await engine.getHeader(blockTag))

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    ?(await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx))

    let callResult = (await engine.evm.call(header, tx, optimisticStateFetch)).valueOr:
      return err((VerificationError, "contract call failed -> " & error))

    if callResult.error.len() > 0:
      return err((VerificationError, callResult.error))

    ok(callResult.output)

  engine.frontend.eth_createAccessList = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
    if tx.to.isNone():
      return err((InvalidDataError, "to address is required"))

    let header = ?(await engine.getHeader(blockTag))

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    ?(await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx))

    let (accessList, error, gasUsed) = (
      await engine.evm.createAccessList(header, tx, optimisticStateFetch)
    ).valueOr:
      return err((VerificationError, "access list calculation failed -> " & error))

    ok(
      AccessListResult(accessList: accessList, error: error, gasUsed: gasUsed.Quantity)
    )

  engine.frontend.eth_estimateGas = proc(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: bool = true
  ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).} =
    if tx.to.isNone():
      return err((VerificationError, "to address is required"))

    let header = ?(await engine.getHeader(blockTag))

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    ?(await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx))

    let gasEstimate = (await engine.evm.estimateGas(header, tx, optimisticStateFetch)).valueOr:
      return err((VerificationError, "gas estimation calculation failed -> " & error))

    ok(Quantity(gasEstimate))

  engine.frontend.eth_getTransactionByHash = proc(
      txHash: Hash32
  ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
    let
      backend = ?(engine.backendFor(GetTransactionByHash))
      tx = ?(await backend.eth_getTransactionByHash(txHash))

    if tx.hash != txHash:
      return err(
        (
          VerificationError,
          "the downloaded transaction hash doesn't match the requested transaction hash",
        )
      )

    if not checkTxHash(tx, txHash):
      return
        err((VerificationError, "the transaction doesn't hash to the provided hash"))

    ok(tx)

  engine.frontend.eth_getBlockReceipts = proc(
      blockTag: BlockTag
  ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.async: (raises: [CancelledError]).} =
    let rxs = ?(await engine.getReceipts(blockTag))
    ok(Opt.some(rxs))

  engine.frontend.eth_getTransactionReceipt = proc(
      txHash: Hash32
  ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
    let
      backend = ?(engine.backendFor(GetTransactionReceipt))
      rx = ?(await backend.eth_getTransactionReceipt(txHash))
      rxs = ?(await engine.getReceipts(rx.blockHash))

    for r in rxs:
      if r.transactionHash == txHash:
        return ok(r)

    return err((VerificationError, "receipt couldn't be verified"))

  engine.frontend.eth_getLogs = proc(
      filterOptions: FilterOptions
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    await engine.getLogs(filterOptions)

  engine.frontend.eth_newFilter = proc(
      filterOptions: FilterOptions
  ): Future[EngineResult[string]] {.async: (raises: [CancelledError]).} =
    if engine.filterStore.len >= MAX_FILTERS:
      return err((UnavailableDataError, "FilterStore already full"))

    var
      id: array[8, byte] # 64bits
      strId: string

    for i in 0 .. (MAX_ID_TRIES + 1):
      if randomBytes(id) != len(id):
        return err(
          (InvalidDataError, "Couldn't generate a random identifier for the filter")
        )

      strId = toHex(id)

      if not engine.filterStore.contains(strId):
        break

      if i >= MAX_ID_TRIES:
        return
          err((InvalidDataError, "Couldn't create a unique identifier for the filter"))

    engine.filterStore[strId] =
      FilterStoreItem(filter: filterOptions, blockMarker: Opt.none(Quantity))

    ok(strId)

  engine.frontend.eth_uninstallFilter = proc(
      filterId: string
  ): Future[EngineResult[bool]] {.async: (raises: [CancelledError]).} =
    if filterId in engine.filterStore:
      engine.filterStore.del(filterId)
      return ok(true)

    ok(false)

  engine.frontend.eth_getFilterLogs = proc(
      filterId: string
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    try:
      await engine.getLogs(engine.filterStore[filterId].filter)
    except KeyError as e:
      err((InvalidDataError, "Filter doesn't exist"))

  engine.frontend.eth_getFilterChanges = proc(
      filterId: string
  ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
    let filterItem =
      try:
        engine.filterStore[filterId]
      except KeyError as e:
        return err((InvalidDataError, "Filter doesn't exist"))

    let
      filter = ?engine.resolveFilterTags(filterItem.filter)
      # after resolving toBlock is always some and a number tag
      toBlock = filter.toBlock.get().number

    if filterItem.blockMarker.isSome() and toBlock <= filterItem.blockMarker.get():
      return
        err((UnavailableDataError, "No changes for the filter since the last query"))

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
      logObjs = ?(await engine.getLogs(changesFilter))

    # all logs verified so we can update blockMarker
    try:
      engine.filterStore[filterId].blockMarker = Opt.some(toBlock)
    except KeyError as e:
      return err((UnavailableDataError, "Filter doesn't exist"))

    ok(logObjs)

  engine.frontend.eth_blobBaseFee = proc(): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
  .} =
    let com = CommonRef.new(
      DefaultDbMemory.newCoreDbRef(),
      config = chainConfigForNetwork(engine.chainId),
      initializeDb = false,
      statelessProviderEnabled = true, # Enables collection of witness keys
    )

    let header = ?(await engine.getHeader(blockId("latest")))

    if header.blobGasUsed.isNone():
      return err((VerificationError, "blobGasUsed missing from latest header"))
    if header.excessBlobGas.isNone():
      return err((VerificationError, "excessBlobGas missing from latest header"))
    let blobBaseFee =
      getBlobBaseFee(header.excessBlobGas.get, com, com.toEVMFork(header)) *
      header.blobGasUsed.get.u256

    ok(blobBaseFee)

  engine.frontend.eth_gasPrice = proc(): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
  .} =
    let suggestedPrice = ?(await engine.suggestGasPrice())

    ok(Quantity(suggestedPrice.uint64))

  engine.frontend.eth_maxPriorityFeePerGas = proc(): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
  .} =
    let suggestedPrice = ?(await engine.suggestMaxPriorityGasPrice())

    ok(Quantity(suggestedPrice.uint64))

  # pass-forward
  engine.frontend.eth_getProof = proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
  ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
    let backend = ?(engine.backendFor(GetProof))
    await backend.eth_getProof(address, slots, blockId)

  engine.frontend.eth_feeHistory = proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
  ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
    let backend = ?(engine.backendFor(FeeHistory))
    await backend.eth_feeHistory(blockCount, newestBlock, rewardPercentiles)

  engine.frontend.eth_sendRawTransaction = proc(
      txBytes: seq[byte]
  ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
    let backend = ?(engine.backendFor(SendRawTransaction))
    await backend.eth_sendRawTransaction(txBytes)

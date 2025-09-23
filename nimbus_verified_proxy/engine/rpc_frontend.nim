# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
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
  engine.frontend.eth_chainId = proc(): Future[UInt256] {.async.} =
    engine.chainId

  engine.frontend.eth_blockNumber = proc(): Future[uint64] {.async.} =
    ## Returns the number of the most recent block.
    let latest = engine.headerStore.latest.valueOr:
      raise newException(ValueError, "Syncing")

    latest.number.uint64

  engine.frontend.eth_getBalance = proc(address: Address, quantityTag: BlockTag): Future[UInt256] {.async.} =
    let
      header = (await engine.getHeader(quantityTag)).valueOr:
        raise newException(ValueError, error)
      account = (await engine.getAccount(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    account.balance

  engine.frontend.eth_getStorageAt = proc(address: Address, slot: UInt256, quantityTag: BlockTag): Future[FixedBytes[32]] {.async.} =
    let
      header = (await engine.getHeader(quantityTag)).valueOr:
        raise newException(ValueError, error)
      storage = (await engine.getStorageAt(address, slot, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    storage.to(Bytes32)

  engine.frontend.eth_getTransactionCount = proc(address: Address, quantityTag: BlockTag): Future[Quantity] {.async.} =
    let
      header = (await engine.getHeader(quantityTag)).valueOr:
        raise newException(ValueError, error)
      account = (await engine.getAccount(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    Quantity(account.nonce)

  engine.frontend.eth_getCode = proc(address: Address, quantityTag: BlockTag): Future[seq[byte]] {.async.} =
    let
      header = (await engine.getHeader(quantityTag)).valueOr:
        raise newException(ValueError, error)
      code = (await engine.getCode(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    code

  engine.frontend.eth_getBlockByHash = proc(blockHash: Hash32, fullTransactions: bool): Future[BlockObject] {.async.} =
    (await engine.getBlock(blockHash, fullTransactions)).valueOr:
      raise newException(ValueError, error)

  engine.frontend.eth_getBlockByNumber = proc(blockTag: BlockTag, fullTransactions: bool): Future[BlockObject] {.async.} =
    (await engine.getBlock(blockTag, fullTransactions)).valueOr:
      raise newException(ValueError, error)

  engine.frontend.eth_getUncleCountByBlockNumber = proc(blockTag: BlockTag): Future[Quantity] {.async.} =
    let blk = (await engine.getBlock(blockTag, false)).valueOr:
      raise newException(ValueError, error)

    Quantity(blk.uncles.len())

  engine.frontend.eth_getUncleCountByBlockHash = proc(blockHash: Hash32): Future[Quantity] {.async.} =
    let blk = (await engine.getBlock(blockHash, false)).valueOr:
      raise newException(ValueError, error)

    Quantity(blk.uncles.len())

  engine.frontend.eth_getBlockTransactionCountByNumber = proc(blockTag: BlockTag): Future[Quantity] {.async.} =
    let blk = (await engine.getBlock(blockTag, true)).valueOr:
      raise newException(ValueError, error)

    Quantity(blk.transactions.len)

  engine.frontend.eth_getBlockTransactionCountByHash = proc(blockHash: Hash32): Future[Quantity] {.async.} =
    let blk = (await engine.getBlock(blockHash, true)).valueOr:
      raise newException(ValueError, error)

    Quantity(blk.transactions.len)

  engine.frontend.eth_getTransactionByBlockNumberAndIndex = proc(blockTag: BlockTag, index: Quantity): Future[TransactionObject] {.async.} =
    let blk = (await engine.getBlock(blockTag, true)).valueOr:
      raise newException(ValueError, error)

    if distinctBase(index) >= uint64(blk.transactions.len):
      raise newException(ValueError, "provided transaction index is outside bounds")
    let x = blk.transactions[distinctBase(index)]

    doAssert x.kind == tohTx

    x.tx

  engine.frontend.eth_getTransactionByBlockHashAndIndex = proc(blockHash: Hash32, index: Quantity): Future[TransactionObject] {.async.} =
    let blk = (await engine.getBlock(blockHash, true)).valueOr:
      raise newException(ValueError, error)

    if distinctBase(index) >= uint64(blk.transactions.len):
      raise newException(ValueError, "provided transaction index is outside bounds")
    let x = blk.transactions[distinctBase(index)]

    doAssert x.kind == tohTx

    x.tx

  engine.frontend.eth_call = proc(tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]): Future[seq[byte]] {.async.} =
    if tx.to.isNone():
      raise newException(ValueError, "to address is required")

    let
      header = (await engine.getHeader(blockTag)).valueOr:
        raise newException(ValueError, error)
      optimisticStateFetch = optimisticStateFetch.valueOr:
        true

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    (await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)).isOkOr:
      raise newException(ValueError, error)

    let callResult = (await engine.evm.call(header, tx, optimisticStateFetch)).valueOr:
      raise newException(ValueError, error)

    if callResult.error.len() > 0:
      raise (ref ApplicationError)(
        code: 3,
        msg: callResult.error,
        data: Opt.some(JsonString("\"" & callResult.output.to0xHex() & "\"")),
      )

    return callResult.output

  engine.frontend.eth_createAccessList = proc(tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]): Future[AccessListResult] {.async.} =
    if tx.to.isNone():
      raise newException(ValueError, "to address is required")

    let
      header = (await engine.getHeader(blockTag)).valueOr:
        raise newException(ValueError, error)
      optimisticStateFetch = optimisticStateFetch.valueOr:
        true

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    (await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)).isOkOr:
      raise newException(ValueError, error)

    let (accessList, error, gasUsed) = (
      await engine.evm.createAccessList(header, tx, optimisticStateFetch)
    ).valueOr:
      raise newException(ValueError, error)

    return
      AccessListResult(accessList: accessList, error: error, gasUsed: gasUsed.Quantity)

  engine.frontend.eth_estimateGas = proc(tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]): Future[Quantity] {.async.} =
    if tx.to.isNone():
      raise newException(ValueError, "to address is required")

    let
      header = (await engine.getHeader(blockTag)).valueOr:
        raise newException(ValueError, error)

      optimisticStateFetch = optimisticStateFetch.valueOr:
        true

    # Start fetching code to get it in the code cache
    discard engine.getCode(tx.to.get(), header.number, header.stateRoot)

    # As a performance optimisation we concurrently pre-fetch the state needed
    # for the call by calling eth_createAccessList and then using the returned
    # access list keys to fetch the required state using eth_getProof.
    (await engine.populateCachesUsingAccessList(header.number, header.stateRoot, tx)).isOkOr:
      raise newException(ValueError, error)

    let gasEstimate = (await engine.evm.estimateGas(header, tx, optimisticStateFetch)).valueOr:
      raise newException(ValueError, error)

    return gasEstimate.Quantity

  engine.frontend.eth_getTransactionByHash = proc(txHash: Hash32): Future[TransactionObject] {.async.} =
    let tx =
      try:
        await engine.backend.eth_getTransactionByHash(txHash)
      except CatchableError as e:
        raise newException(ValueError, e.msg)

    if tx.hash != txHash:
      raise newException(
        ValueError,
        "the downloaded transaction hash doesn't match the requested transaction hash",
      )

    if not checkTxHash(tx, txHash):
      raise
        newException(ValueError, "the transaction doesn't hash to the provided hash")

    return tx

  engine.frontend.eth_getBlockReceipts = proc(blockTag: BlockTag): Future[Opt[seq[ReceiptObject]]] {.async.} =
    let rxs = (await engine.getReceipts(blockTag)).valueOr:
      raise newException(ValueError, error)
    return Opt.some(rxs)

  engine.frontend.eth_getTransactionReceipt = proc(txHash: Hash32): Future[ReceiptObject] {.async.} =
    let
      rx =
        try:
          await engine.backend.eth_getTransactionReceipt(txHash)
        except CatchableError as e:
          raise newException(ValueError, e.msg)
      rxs = (await engine.getReceipts(rx.blockHash)).valueOr:
        raise newException(ValueError, error)

    for r in rxs:
      if r.transactionHash == txHash:
        return r

    raise newException(ValueError, "receipt couldn't be verified")

  engine.frontend.eth_getLogs = proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.async.} =
    (await engine.getLogs(filterOptions)).valueOr:
      raise newException(ValueError, error)

  engine.frontend.eth_newFilter = proc(filterOptions: FilterOptions): Future[string] {.async.} =
    if engine.filterStore.len >= MAX_FILTERS:
      raise newException(ValueError, "FilterStore already full")

    var
      id: array[8, byte] # 64bits
      strId: string

    for i in 0 .. (MAX_ID_TRIES + 1):
      if randomBytes(id) != len(id):
        raise newException(
          ValueError, "Couldn't generate a random identifier for the filter"
        )

      strId = toHex(id)

      if not engine.filterStore.contains(strId):
        break

      if i >= MAX_ID_TRIES:
        raise
          newException(ValueError, "Couldn't create a unique identifier for the filter")

    engine.filterStore[strId] =
      FilterStoreItem(filter: filterOptions, blockMarker: Opt.none(Quantity))

    return strId

  engine.frontend.eth_uninstallFilter = proc(filterId: string): Future[bool] {.async.} =
    if filterId in engine.filterStore:
      engine.filterStore.del(filterId)
      return true

    return false

  engine.frontend.eth_getFilterLogs = proc(filterId: string): Future[seq[LogObject]] {.async.} =
    if filterId notin engine.filterStore:
      raise newException(ValueError, "Filter doesn't exist")

    (await engine.getLogs(engine.filterStore[filterId].filter)).valueOr:
      raise newException(ValueError, error)

  engine.frontend.eth_getFilterChanges = proc(filterId: string): Future[seq[LogObject]] {.async.} =
    if filterId notin engine.filterStore:
      raise newException(ValueError, "Filter doesn't exist")

    let
      filterItem = engine.filterStore[filterId]
      filter = engine.resolveFilterTags(filterItem.filter).valueOr:
        raise newException(ValueError, error)
      # after resolving toBlock is always some and a number tag
      toBlock = filter.toBlock.get().number

    if filterItem.blockMarker.isSome() and toBlock <= filterItem.blockMarker.get():
      raise newException(ValueError, "No changes for the filter since the last query")

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
      logObjs = (await engine.getLogs(changesFilter)).valueOr:
        raise newException(ValueError, error)

    # all logs verified so we can update blockMarker
    engine.filterStore[filterId].blockMarker = Opt.some(toBlock)

    return logObjs

  engine.frontend.eth_blobBaseFee = proc(): Future[UInt256] {.async.} =
    let com = CommonRef.new(
      DefaultDbMemory.newCoreDbRef(),
      taskpool = nil,
      config = chainConfigForNetwork(engine.chainId),
      initializeDb = false,
      statelessProviderEnabled = true, # Enables collection of witness keys
    )

    let header = (await engine.getHeader(blockId("latest"))).valueOr:
      raise newException(ValueError, error)

    if header.blobGasUsed.isNone():
      raise newException(ValueError, "blobGasUsed missing from latest header")
    if header.excessBlobGas.isNone():
      raise newException(ValueError, "excessBlobGas missing from latest header")
    let blobBaseFee =
      getBlobBaseFee(header.excessBlobGas.get, com, com.toEVMFork(header)) *
      header.blobGasUsed.get.u256
    return blobBaseFee

  engine.frontend.eth_gasPrice = proc(): Future[Quantity] {.async.} =
    let suggestedPrice = (await engine.suggestGasPrice()).valueOr:
      raise newException(ValueError, error)

    Quantity(suggestedPrice.uint64)

  engine.frontend.eth_maxPriorityFeePerGas = proc(): Future[Quantity] {.async.} =
    let suggestedPrice = (await engine.suggestMaxPriorityGasPrice()).valueOr:
      raise newException(ValueError, error)

    Quantity(suggestedPrice.uint64)

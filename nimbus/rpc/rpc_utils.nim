# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[strutils, algorithm, options],
  ./rpc_types,
  ./params,
  ../common/common,
  ../db/core_db,
  ../db/ledger,
  ../constants, stint,
  ../utils/utils,
  ../transaction,
  ../transaction/call_evm,
  ../core/eip4844,
  ../beacon/web3_eth_conv,
  ../vm_types,
  ../vm_state,
  ../evm/precompiles,
  ../evm/tracer/access_list_tracer


const
  defaultTag = blockId("latest")

type
  BlockHeader = common.BlockHeader

proc headerFromTag*(chain: CoreDbRef, blockId: BlockTag): BlockHeader
    {.gcsafe, raises: [CatchableError].} =

  if blockId.kind == bidAlias:
    let tag = blockId.alias.toLowerAscii
    case tag
    of "latest": result = chain.getCanonicalHead()
    of "earliest": result = chain.getBlockHeader(GENESIS_BLOCK_NUMBER)
    of "safe": result = chain.safeHeader()
    of "finalized": result = chain.finalizedHeader()
    of "pending":
      #TODO: Implement get pending block
      result = chain.getCanonicalHead()
    else:
      raise newException(ValueError, "Unsupported block tag " & tag)
  else:
    let blockNum = blockId.number.uint64.toBlockNumber
    result = chain.getBlockHeader(blockNum)

proc headerFromTag*(chain: CoreDbRef, blockTag: Option[BlockTag]): BlockHeader
    {.gcsafe, raises: [CatchableError].} =
  let blockId = blockTag.get(defaultTag)
  chain.headerFromTag(blockId)

proc calculateMedianGasPrice*(chain: CoreDbRef): GasInt
    {.gcsafe, raises: [CatchableError].} =
  var prices  = newSeqOfCap[GasInt](64)
  let header = chain.getCanonicalHead()
  for tx in chain.getBlockTransactions(header):
    prices.add(tx.payload.max_fee_per_gas.truncate(int64))

  if prices.len > 0:
    sort(prices)
    let middle = prices.len div 2
    if prices.len mod 2 == 0:
      # prevent overflow
      let price = prices[middle].uint64 + prices[middle - 1].uint64
      result = (price div 2).GasInt
    else:
      result = prices[middle]

  const minGasPrice = 30_000_000_000.GasInt
  result = max(result, minGasPrice)

proc unsignedTx*(
    tx: TransactionArgs,
    chain: CoreDbRef,
    defaultNonce: AccountNonce,
    eip155 = true
): TransactionPayload {.gcsafe, raises: [CatchableError].} =
  TransactionPayload(
    nonce:
      if tx.nonce.isSome:
        tx.nonce.get.AccountNonce
      else:
        defaultNonce,
    max_fee_per_gas:
      if tx.gasPrice.isSome:
        distinctBase(tx.gasPrice.get).u256
      else:
        calculateMedianGasPrice(chain).uint64.u256,
    gas:
      if tx.gas.isSome:
        distinctBase(tx.gas.get)
      else:
        90000,
    to:
      if tx.to.isSome:
        Opt.some ethAddr(tx.to.get)
      else:
        Opt.none(EthAddress),
    value:
      if tx.value.isSome:
        tx.value.get
      else:
        UInt256.zero,
    input:
      if tx.payload.len > MAX_CALL_DATA_SIZE:
        raise (ref ValueError)(msg: "tx.payload exceeds MAX_CALL_DATA_SIZE")
      else:
        List[byte, Limit MAX_CALL_DATA_SIZE].init(tx.payload),
    tx_type:
      if eip155:
        Opt.some TxLegacy
      else:
        Opt.none TxType)

proc toWd(wd: Withdrawal): WithdrawalObject =
  WithdrawalObject(
    index: w3Qty wd.index,
    validatorIndex: w3Qty wd.validatorIndex,
    address: w3Addr wd.address,
    amount: w3Qty wd.amount,
  )

proc toWdList(list: openArray[Withdrawal]): seq[WithdrawalObject] =
  result = newSeqOfCap[WithdrawalObject](list.len)
  for x in list:
    result.add toWd(x)

proc populateTransactionObject*(tx: Transaction,
                                chainId: ChainId,
                                optionalHeader: Option[BlockHeader] = none(BlockHeader),
                                txIndex: Option[int] = none(int)): TransactionObject
    {.gcsafe, raises: [ValidationError].} =
  let anyTx = AnyTransaction.fromOneOfBase(tx).valueOr:
    raiseAssert "Cannot convert invalid `Transaction`: " & $tx
  withTxVariant(anyTx):
    result = TransactionObject()
    when txKind >= TransactionKind.Legacy:
      result.`type` = options.some w3Qty(txVariant.payload.tx_type.ord)
    if optionalHeader.isSome:
      let header = optionalHeader.get
      result.blockHash = some(w3Hash header.hash)
      result.blockNumber = some(w3BlockNumber(header.blockNumber))

    result.`from` = w3Addr txVariant.signature.from_address
    result.gas = w3Qty(txVariant.payload.gas)
    result.gasPrice = w3Qty(txVariant.payload.max_fee_per_gas)
    result.hash = w3Hash txVariant.payload.compute_sig_hash(chainId)
    result.input = distinctBase(txVariant.payload.input)
    result.nonce = w3Qty(txVariant.payload.nonce)
    when txKind == TransactionKind.Eip4844:
      result.to = some(w3Addr txVariant.payload.to)
    else:
      if txVariant.payload.to.isSome:
        result.to = some(w3Addr txVariant.payload.to.unsafeGet)
    if txIndex.isSome:
      result.transactionIndex = some(w3Qty(txIndex.get))
    result.value = txVariant.payload.value
    let
      (yParity, r, s) = ecdsa_unpack_signature(
        txVariant.signature.ecdsa_signature)
      v =
        when txKind == TransactionKind.Replayable:
          if yParity: 28.u256 else: 27.u256
        elif txKind == TransactionKind.Legacy:
          distinctBase(chainId).u256 * 2 + (if yParity: 36.u256 else: 35.u256)
        else:
          if yParity: UInt256.one else: UInt256.zero
    result.v = w3Qty(v)
    result.r = u256(r)
    result.s = u256(s)
    when txKind >= TransactionKind.Eip1559:
      result.maxFeePerGas = some w3Qty(txVariant.payload.max_fee_per_gas)
      result.maxPriorityFeePerGas = some w3Qty(
        txVariant.payload.max_priority_fee_per_gas)

    when txKind >= TransactionKind.Eip2930:
      result.chainId = some(Web3Quantity(chainId))
      result.accessList = some(w3AccessList(txVariant.payload.access_list))

    when txKind == TransactionKind.Eip4844:
      result.maxFeePerBlobGas = some(txVariant.payload.max_fee_per_blob_gas)
      result.blobVersionedHashes =
        some(w3Hashes distinctBase(txVariant.payload.blob_versioned_hashes))

proc populateBlockObject*(header: BlockHeader, chain: CoreDbRef, fullTx: bool, isUncle = false): BlockObject
    {.gcsafe, raises: [CatchableError].} =
  let blockHash = header.blockHash
  result = BlockObject()

  result.number = w3BlockNumber(header.blockNumber)
  result.hash = w3Hash blockHash
  result.parentHash = w3Hash header.parentHash
  result.nonce = some(FixedBytes[8] header.nonce)
  result.sha3Uncles = w3Hash header.ommersHash
  result.logsBloom = FixedBytes[256] header.bloom
  result.transactionsRoot = w3Hash header.txRoot
  result.stateRoot = w3Hash header.stateRoot
  result.receiptsRoot = w3Hash header.receiptRoot
  result.miner = w3Addr header.coinbase
  result.difficulty = header.difficulty
  result.extraData = HistoricExtraData header.extraData
  result.mixHash = w3Hash header.mixDigest

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(BlockHeader) - sizeof(common.Blob) + header.extraData.len
  result.size = w3Qty(size)

  result.gasLimit  = w3Qty(header.gasLimit)
  result.gasUsed   = w3Qty(header.gasUsed)
  result.timestamp = w3Qty(header.timestamp)
  result.baseFeePerGas = if header.fee.isSome:
                           some(header.baseFee)
                         else:
                           none(UInt256)
  if not isUncle:
    result.totalDifficulty = chain.getScore(blockHash)
    result.uncles = w3Hashes chain.getUncleHashes(header)

    if fullTx:
      var i = 0
      for tx in chain.getBlockTransactions(header):
        result.transactions.add txOrHash(
          populateTransactionObject(tx, chain.chainId, some(header), some(i)))
        inc i
    else:
      for x in chain.getBlockTransactionHashes(header):
        result.transactions.add txOrHash(w3Hash(x))

  if header.withdrawalsRoot.isSome:
    result.withdrawalsRoot = some(w3Hash header.withdrawalsRoot.get)
    result.withdrawals = some(toWdList(chain.getWithdrawals(header.withdrawalsRoot.get)))

  if header.blobGasUsed.isSome:
    result.blobGasUsed = some(w3Qty(header.blobGasUsed.get))

  if header.excessBlobGas.isSome:
    result.excessBlobGas = some(w3Qty(header.excessBlobGas.get))

  if header.parentBeaconBlockRoot.isSome:
    result.parentBeaconBlockRoot = some(w3Hash header.parentBeaconBlockRoot.get)

proc populateReceipt*(receipt: Receipt, gasUsed: GasInt, tx: Transaction,
                      txIndex: int, header: BlockHeader): ReceiptObject
    {.gcsafe, raises: [ValidationError].} =
  result = ReceiptObject()
  result.transactionHash = w3Hash tx.rlpHash
  result.transactionIndex = w3Qty(txIndex)
  result.blockHash = w3Hash header.hash
  result.blockNumber = w3BlockNumber(header.blockNumber)
  result.`from` = w3Addr tx.getSender()
  result.to = some(w3Addr tx.destination)
  result.cumulativeGasUsed = w3Qty(receipt.cumulativeGasUsed)
  result.gasUsed = w3Qty(gasUsed)
  result.`type` = some w3Qty(receipt.receiptType.ord)

  if tx.contractCreation:
    var sender: EthAddress
    if tx.getSender(sender):
      let contractAddress = generateAddress(sender, tx.payload.nonce)
      result.contractAddress = some(w3Addr contractAddress)

  for log in receipt.logs:
    # TODO: Work everywhere with either `Hash256` as topic or `array[32, byte]`
    var topics: seq[Web3Topic]
    for topic in log.topics:
      topics.add Web3Topic(topic)

    let logObject = FilterLog(
      removed: false,
      # TODO: Not sure what is difference between logIndex and TxIndex and how
      # to calculate it.
      logIndex: some(result.transactionIndex),
      # Note: the next 4 fields cause a lot of duplication of data, but the spec
      # is what it is. Not sure if other clients actually add this.
      transactionIndex: some(result.transactionIndex),
      transactionHash: some(result.transactionHash),
      blockHash: some(result.blockHash),
      blockNumber: some(result.blockNumber),
      # The actual fields
      address: w3Addr log.address,
      data: log.data,
      topics: topics
    )
    result.logs.add(logObject)

  result.logsBloom = FixedBytes[256] receipt.bloom

  # post-transaction stateroot (pre Byzantium).
  if receipt.hasStateRoot:
    result.root = some(w3Hash receipt.stateRoot)
  else:
    # 1 = success, 0 = failure.
    result.status = some(w3Qty(receipt.status.uint64))

  result.effectiveGasPrice = w3Qty(
    (header.baseFee + min(
      tx.payload.max_priority_fee_per_gas.get(tx.payload.max_fee_per_gas),
      tx.payload.max_fee_per_gas - header.baseFee)).truncate(int64))

  if tx.payload.blob_versioned_hashes.isSome:
    result.blobGasUsed = some(w3Qty(
      tx.payload.blob_versioned_hashes.unsafeGet.len.uint64 *
      GAS_PER_BLOB.uint64))
    result.blobGasPrice = some(getBlobBaseFee(header.excessBlobGas.get(0'u64)))

proc createAccessList*(header: BlockHeader,
                       com: CommonRef,
                       args: TransactionArgs): AccessListResult {.gcsafe, raises:[CatchableError].} =
  var args = args

  # If the gas amount is not set, default to RPC gas cap.
  if args.gas.isNone:
    args.gas = some(Quantity DEFAULT_RPC_GAS_CAP)

  let
    vmState = BaseVMState.new(header, com)
    fork    = com.toEVMFork(forkDeterminationInfo(header.blockNumber, header.timestamp))
    sender  = args.sender
    # TODO: nonce should be retrieved from txPool
    nonce   = vmState.stateDB.getNonce(sender)
    to      = if args.to.isSome: ethAddr args.to.get
              else: generateAddress(sender, nonce)
    precompiles = activePrecompilesList(fork)

  var
    prevTracer = AccessListTracer.new(
      ethAccessList args.accessList,
      sender,
      to,
      precompiles)

  while true:
    # Retrieve the current access list to expand
    let accessList = prevTracer.accessList()

    # Set the accesslist to the last accessList
    # generated by prevTracer
    args.accessList = some(w3AccessList accessList)

    # Apply the transaction with the access list tracer
    let
      tracer  = AccessListTracer.new(accessList, sender, to, precompiles)
      vmState = BaseVMState.new(header, com, tracer)
      res     = rpcCallEvm(args, header, com, vmState)

    if res.isError:
      return AccessListResult(
        error: some("failed to apply transaction: " & res.error),
      )

    if tracer.equal(prevTracer):
      return AccessListResult(
        accessList: w3AccessList accessList,
        gasUsed: w3Qty res.gasUsed,
      )

    prevTracer = tracer

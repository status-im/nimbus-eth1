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
  for encodedTx in chain.getBlockTransactionData(header.txRoot):
    let tx = decodeTx(encodedTx)
    prices.add(tx.gasPrice)

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

proc unsignedTx*(tx: TransactionArgs, chain: CoreDbRef, defaultNonce: AccountNonce): Transaction
    {.gcsafe, raises: [CatchableError].} =
  if tx.to.isSome:
    result.to = some(ethAddr(tx.to.get))

  if tx.gas.isSome:
    result.gasLimit = tx.gas.get.GasInt
  else:
    result.gasLimit = 90000.GasInt

  if tx.gasPrice.isSome:
    result.gasPrice = tx.gasPrice.get.GasInt
  else:
    result.gasPrice = calculateMedianGasPrice(chain)

  if tx.value.isSome:
    result.value = tx.value.get
  else:
    result.value = 0.u256

  if tx.nonce.isSome:
    result.nonce = tx.nonce.get.AccountNonce
  else:
    result.nonce = defaultNonce

  result.payload = tx.payload

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
                                optionalHeader: Option[BlockHeader] = none(BlockHeader),
                                txIndex: Option[int] = none(int)): TransactionObject
    {.gcsafe, raises: [ValidationError].} =
  result = TransactionObject()
  result.`type` = some w3Qty(tx.txType.ord)
  if optionalHeader.isSome:
    let header = optionalHeader.get
    result.blockHash = some(w3Hash header.hash)
    result.blockNumber = some(w3BlockNumber(header.blockNumber))

  result.`from` = w3Addr tx.getSender()
  result.gas = w3Qty(tx.gasLimit)
  result.gasPrice = w3Qty(tx.gasPrice)
  result.hash = w3Hash tx.rlpHash
  result.input = tx.payload
  result.nonce = w3Qty(tx.nonce)
  result.to = some(w3Addr tx.destination)
  if txIndex.isSome:
    result.transactionIndex = some(w3Qty(txIndex.get))
  result.value = tx.value
  result.v = w3Qty(tx.V)
  result.r = u256(tx.R)
  result.s = u256(tx.S)
  result.maxFeePerGas = some w3Qty(tx.maxFee)
  result.maxPriorityFeePerGas = some w3Qty(tx.maxPriorityFee)

  if tx.txType >= TxEip2930:
    result.chainId = some(Web3Quantity(tx.chainId))
    result.accessList = some(w3AccessList(tx.accessList))

  if tx.txType >= TxEIP4844:
    result.maxFeePerBlobGas = some(tx.maxFeePerBlobGas)
    result.blobVersionedHashes = some(w3Hashes tx.versionedHashes)

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
        result.transactions.add txOrHash(populateTransactionObject(tx, some(header), some(i)))
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
      let contractAddress = generateAddress(sender, tx.nonce)
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

  let normTx = eip1559TxNormalization(tx, header.baseFee.truncate(GasInt))
  result.effectiveGasPrice = w3Qty(normTx.gasPrice)

  if tx.txType == TxEip4844:
    result.blobGasUsed = some(w3Qty(tx.versionedHashes.len.uint64 * GAS_PER_BLOB.uint64))
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

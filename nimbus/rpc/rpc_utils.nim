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
  std/[strutils, algorithm],
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
  ../evm/types,
  ../evm/state,
  ../evm/precompiles,
  ../evm/tracer/access_list_tracer,
  ../evm/evm_errors


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
      # We currently fall back to `latest` so that the `tx-spammer` in
      # `ethpandaops/ethereum-package` can make progress. A real
      # implementation is still required that takes into account any
      # pending transactions that have not yet been bundled into a block.
      result = chain.getCanonicalHead()
    else:
      raise newException(ValueError, "Unsupported block tag " & tag)
  else:
    let blockNum = blockId.number.uint64
    result = chain.getBlockHeader(blockNum)

proc headerFromTag*(chain: CoreDbRef, blockTag: Opt[BlockTag]): BlockHeader
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

  # TODO: This should properly incorporate the base fee in the block data,
  # and recommend a gas fee that likely gets the block to confirm.
  # This also has to work on Genesis where no prior transaction data exists.
  # For compatibility with `ethpandaops/ethereum-package`, set this to a
  # sane minimum for compatibility to unblock testing.
  # Note: When this is fixed, update `tests/graphql/queries.toml` and
  # re-enable the "query.gasPrice" test case (remove `skip = true`).
  const minGasPrice = 30_000_000_000.GasInt
  result = max(result, minGasPrice)

proc unsignedTx*(tx: TransactionArgs, chain: CoreDbRef, defaultNonce: AccountNonce): Transaction
    {.gcsafe, raises: [CatchableError].} =
  if tx.to.isSome:
    result.to = Opt.some(ethAddr(tx.to.get))

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
                                optionalHeader: Opt[BlockHeader] = Opt.none(BlockHeader),
                                txIndex: Opt[uint64] = Opt.none(uint64)): TransactionObject
    {.gcsafe, raises: [ValidationError].} =
  result = TransactionObject()
  result.`type` = Opt.some Quantity(tx.txType)
  if optionalHeader.isSome:
    let header = optionalHeader.get
    result.blockHash = Opt.some(w3Hash header.blockHash)
    result.blockNumber = Opt.some(w3BlockNumber(header.number))

  result.`from` = w3Addr tx.getSender()
  result.gas = w3Qty(tx.gasLimit)
  result.gasPrice = w3Qty(tx.gasPrice)
  result.hash = w3Hash tx.rlpHash
  result.input = tx.payload
  result.nonce = w3Qty(tx.nonce)
  result.to = Opt.some(w3Addr tx.destination)
  if txIndex.isSome:
    result.transactionIndex = Opt.some(Quantity(txIndex.get))
  result.value = tx.value
  result.v = w3Qty(tx.V)
  result.r = tx.R
  result.s = tx.S
  result.maxFeePerGas = Opt.some w3Qty(tx.maxFeePerGas)
  result.maxPriorityFeePerGas = Opt.some w3Qty(tx.maxPriorityFeePerGas)

  if tx.txType >= TxEip2930:
    result.chainId = Opt.some(Web3Quantity(tx.chainId))
    result.accessList = Opt.some(w3AccessList(tx.accessList))

  if tx.txType >= TxEIP4844:
    result.maxFeePerBlobGas = Opt.some(tx.maxFeePerBlobGas)
    result.blobVersionedHashes = Opt.some(w3Hashes tx.versionedHashes)

proc populateBlockObject*(header: BlockHeader, chain: CoreDbRef, fullTx: bool, isUncle = false): BlockObject
    {.gcsafe, raises: [CatchableError].} =
  let blockHash = header.blockHash
  result = BlockObject()

  result.number = w3BlockNumber(header.number)
  result.hash = w3Hash blockHash
  result.parentHash = w3Hash header.parentHash
  result.nonce = Opt.some(FixedBytes[8] header.nonce)
  result.sha3Uncles = w3Hash header.ommersHash
  result.logsBloom = FixedBytes[256] header.logsBloom
  result.transactionsRoot = w3Hash header.txRoot
  result.stateRoot = w3Hash header.stateRoot
  result.receiptsRoot = w3Hash header.receiptsRoot
  result.miner = w3Addr header.coinbase
  result.difficulty = header.difficulty
  result.extraData = HistoricExtraData header.extraData
  result.mixHash = Hash32 header.mixHash

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(BlockHeader) - sizeof(common.Blob) + header.extraData.len
  result.size = Quantity(size)

  result.gasLimit  = w3Qty(header.gasLimit)
  result.gasUsed   = w3Qty(header.gasUsed)
  result.timestamp = w3Qty(header.timestamp)
  result.baseFeePerGas = header.baseFeePerGas

  if not isUncle:
    result.totalDifficulty = chain.getScore(blockHash).valueOr(0.u256)
    result.uncles = w3Hashes chain.getUncleHashes(header)

    if fullTx:
      var i = 0'u64
      for tx in chain.getBlockTransactions(header):
        result.transactions.add txOrHash(populateTransactionObject(tx, Opt.some(header), Opt.some(i)))
        inc i
    else:
      for x in chain.getBlockTransactionHashes(header):
        result.transactions.add txOrHash(w3Hash(x))

  if header.withdrawalsRoot.isSome:
    result.withdrawalsRoot = Opt.some(w3Hash header.withdrawalsRoot.get)
    result.withdrawals = Opt.some(toWdList(chain.getWithdrawals(header.withdrawalsRoot.get)))

  if header.blobGasUsed.isSome:
    result.blobGasUsed = Opt.some(w3Qty(header.blobGasUsed.get))

  if header.excessBlobGas.isSome:
    result.excessBlobGas = Opt.some(w3Qty(header.excessBlobGas.get))

  if header.parentBeaconBlockRoot.isSome:
    result.parentBeaconBlockRoot = Opt.some(w3Hash header.parentBeaconBlockRoot.get)

proc populateReceipt*(receipt: Receipt, gasUsed: GasInt, tx: Transaction,
                      txIndex: uint64, header: BlockHeader): ReceiptObject
    {.gcsafe, raises: [ValidationError].} =
  result = ReceiptObject()
  result.transactionHash = w3Hash tx.rlpHash
  result.transactionIndex = w3Qty(txIndex)
  result.blockHash = w3Hash header.blockHash
  result.blockNumber = w3BlockNumber(header.number)
  result.`from` = w3Addr tx.getSender()
  result.to = Opt.some(w3Addr tx.destination)
  result.cumulativeGasUsed = w3Qty(receipt.cumulativeGasUsed)
  result.gasUsed = w3Qty(gasUsed)
  result.`type` = Opt.some Quantity(receipt.receiptType)

  if tx.contractCreation:
    var sender: EthAddress
    if tx.getSender(sender):
      let contractAddress = generateAddress(sender, tx.nonce)
      result.contractAddress = Opt.some(w3Addr contractAddress)

  for log in receipt.logs:
    # TODO: Work everywhere with either `Hash256` as topic or `array[32, byte]`
    var topics: seq[Web3Topic]
    for topic in log.topics:
      topics.add Web3Topic(topic)

    let logObject = FilterLog(
      removed: false,
      # TODO: Not sure what is difference between logIndex and TxIndex and how
      # to calculate it.
      logIndex: Opt.some(result.transactionIndex),
      # Note: the next 4 fields cause a lot of duplication of data, but the spec
      # is what it is. Not sure if other clients actually add this.
      transactionIndex: Opt.some(result.transactionIndex),
      transactionHash: Opt.some(result.transactionHash),
      blockHash: Opt.some(result.blockHash),
      blockNumber: Opt.some(result.blockNumber),
      # The actual fields
      address: w3Addr log.address,
      data: log.data,
      topics: topics
    )
    result.logs.add(logObject)

  result.logsBloom = FixedBytes[256] receipt.logsBloom

  # post-transaction stateroot (pre Byzantium).
  if receipt.hasStateRoot:
    result.root = Opt.some(w3Hash receipt.stateRoot)
  else:
    # 1 = success, 0 = failure.
    result.status = Opt.some(w3Qty(receipt.status.uint64))

  let baseFeePerGas = header.baseFeePerGas.get(0.u256)
  let normTx = eip1559TxNormalization(tx, baseFeePerGas.truncate(GasInt))
  result.effectiveGasPrice = w3Qty(normTx.gasPrice)

  if tx.txType == TxEip4844:
    result.blobGasUsed = Opt.some(w3Qty(tx.versionedHashes.len.uint64 * GAS_PER_BLOB.uint64))
    result.blobGasPrice = Opt.some(getBlobBaseFee(header.excessBlobGas.get(0'u64)))

proc createAccessList*(header: BlockHeader,
                       com: CommonRef,
                       args: TransactionArgs): AccessListResult =

  template handleError(msg: string) =
    return AccessListResult(
      error: Opt.some(msg),
    )

  var args = args

  # If the gas amount is not set, default to RPC gas cap.
  if args.gas.isNone:
    args.gas = Opt.some(Quantity DEFAULT_RPC_GAS_CAP)

  let
    vmState = BaseVMState.new(header, com).valueOr:
                handleError("failed to create vmstate: " & $error.code)
    fork    = com.toEVMFork(forkDeterminationInfo(header.number, header.timestamp))
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
    args.accessList = Opt.some(w3AccessList accessList)

    # Apply the transaction with the access list tracer
    let
      tracer  = AccessListTracer.new(accessList, sender, to, precompiles)
      vmState = BaseVMState.new(header, com, tracer).valueOr:
                  handleError("failed to create vmstate: " & $error.code)
      res     = rpcCallEvm(args, header, com, vmState).valueOr:
                  handleError("failed to call evm: " & $error.code)

    if res.isError:
      handleError("failed to apply transaction: " & res.error)

    if tracer.equal(prevTracer):
      return AccessListResult(
        accessList: w3AccessList accessList,
        gasUsed: w3Qty res.gasUsed,
      )

    prevTracer = tracer

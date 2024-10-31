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
  std/[sequtils, strutils, algorithm],
  ./rpc_types,
  ./params,
  ../db/core_db,
  ../db/ledger,
  ../constants, stint,
  ../utils/utils,
  ../transaction,
  ../transaction/call_evm,
  ../core/eip4844,
  ../evm/types,
  ../evm/state,
  ../evm/precompiles,
  ../evm/tracer/access_list_tracer,
  ../evm/evm_errors,
  eth/common/transaction_utils,
  ../common/common,
  web3/eth_api_types

const
  defaultTag = blockId("latest")

proc headerFromTag*(chain: CoreDbRef, blockId: BlockTag): Header
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

proc headerFromTag*(chain: CoreDbRef, blockTag: Opt[BlockTag]): Header
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

proc unsignedTx*(tx: TransactionArgs, chain: CoreDbRef, defaultNonce: AccountNonce, chainId: ChainId): Transaction
    {.gcsafe, raises: [CatchableError].} =
  if tx.to.isSome:
    result.to = Opt.some(tx.to.get)

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
  result.chainId = chainId

proc toWd(wd: Withdrawal): WithdrawalObject =
  WithdrawalObject(
    index: Quantity wd.index,
    validatorIndex: Quantity wd.validatorIndex,
    address: wd.address,
    amount: Quantity wd.amount,
  )

proc toWdList(list: openArray[Withdrawal]): seq[WithdrawalObject] =
  result = newSeqOfCap[WithdrawalObject](list.len)
  for x in list:
    result.add toWd(x)

func toWdList(x: Opt[seq[eth_types.Withdrawal]]):
                     Opt[seq[WithdrawalObject]] =
  if x.isNone: Opt.none(seq[WithdrawalObject])
  else: Opt.some(toWdList x.get)

proc populateTransactionObject*(tx: Transaction,
                                optionalHash: Opt[eth_types.Hash32] = Opt.none(eth_types.Hash32),
                                optionalNumber: Opt[eth_types.BlockNumber] = Opt.none(eth_types.BlockNumber),
                                txIndex: Opt[uint64] = Opt.none(uint64)): TransactionObject =
  result = TransactionObject()
  result.`type` = Opt.some Quantity(tx.txType)
  result.blockHash = optionalHash
  result.blockNumber = w3Qty(optionalNumber)

  if (let sender = tx.recoverSender(); sender.isOk):
    result.`from` = sender[]
  result.gas = Quantity(tx.gasLimit)
  result.gasPrice = Quantity(tx.gasPrice)
  result.hash = tx.rlpHash
  result.input = tx.payload
  result.nonce = Quantity(tx.nonce)
  result.to = Opt.some(tx.destination)
  if txIndex.isSome:
    result.transactionIndex = Opt.some(Quantity(txIndex.get))
  result.value = tx.value
  result.v = Quantity(tx.V)
  result.r = tx.R
  result.s = tx.S
  result.maxFeePerGas = Opt.some Quantity(tx.maxFeePerGas)
  result.maxPriorityFeePerGas = Opt.some Quantity(tx.maxPriorityFeePerGas)

  if tx.txType >= TxEip2930:
    result.chainId = Opt.some(Quantity(tx.chainId))
    result.accessList = Opt.some(tx.accessList)

  if tx.txType >= TxEIP4844:
    result.maxFeePerBlobGas = Opt.some(tx.maxFeePerBlobGas)
    result.blobVersionedHashes = Opt.some(tx.versionedHashes)

proc populateBlockObject*(blockHash: eth_types.Hash32,
                          blk: Block,
                          totalDifficulty: UInt256,
                          fullTx: bool,
                          isUncle = false): BlockObject =
  template header: auto = blk.header

  result = BlockObject()
  result.number = Quantity(header.number)
  result.hash = blockHash
  result.parentHash = header.parentHash
  result.nonce = Opt.some(header.nonce)
  result.sha3Uncles = header.ommersHash
  result.logsBloom = header.logsBloom
  result.transactionsRoot = header.txRoot
  result.stateRoot = header.stateRoot
  result.receiptsRoot = header.receiptsRoot
  result.miner = header.coinbase
  result.difficulty = header.difficulty
  result.extraData = HistoricExtraData header.extraData
  result.mixHash = Hash32 header.mixHash

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(eth_types.Header) - sizeof(eth_api_types.Blob) + header.extraData.len
  result.size = Quantity(size)

  result.gasLimit  = Quantity(header.gasLimit)
  result.gasUsed   = Quantity(header.gasUsed)
  result.timestamp = Quantity(header.timestamp)
  result.baseFeePerGas = header.baseFeePerGas
  result.totalDifficulty = totalDifficulty

  if not isUncle:
    result.uncles = blk.uncles.mapit(it.blockHash)

    if fullTx:
      for i, tx in blk.transactions:
        let txObj = populateTransactionObject(tx,
          Opt.some(blockHash),
          Opt.some(header.number), Opt.some(i.uint64))
        result.transactions.add txOrHash(txObj)
    else:
      for i, tx in blk.transactions:
        let txHash = rlpHash(tx)
        result.transactions.add txOrHash(txHash)

  result.withdrawalsRoot = header.withdrawalsRoot
  result.withdrawals = toWdList blk.withdrawals
  result.parentBeaconBlockRoot = header.parentBeaconBlockRoot
  result.blobGasUsed = w3Qty(header.blobGasUsed)
  result.excessBlobGas = w3Qty(header.excessBlobGas)

proc populateReceipt*(receipt: Receipt, gasUsed: GasInt, tx: Transaction,
                      txIndex: uint64, header: Header): ReceiptObject =
  let sender = tx.recoverSender()
  result = ReceiptObject()
  result.transactionHash = tx.rlpHash
  result.transactionIndex = Quantity(txIndex)
  result.blockHash = header.blockHash
  result.blockNumber = Quantity(header.number)
  if sender.isSome():
    result.`from` = sender.get()
  result.to = Opt.some(tx.destination)
  result.cumulativeGasUsed = Quantity(receipt.cumulativeGasUsed)
  result.gasUsed = Quantity(gasUsed)
  result.`type` = Opt.some Quantity(receipt.receiptType)

  if tx.contractCreation and sender.isSome:
    result.contractAddress = Opt.some(tx.creationAddress(sender[]))

  for log in receipt.logs:
    # TODO: Work everywhere with either `Hash32` as topic or `array[32, byte]`
    var topics: seq[Bytes32]
    for topic in log.topics:
      topics.add (topic)

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
      address: log.address,
      data: log.data,
      topics: topics
    )
    result.logs.add(logObject)

  result.logsBloom = FixedBytes[256] receipt.logsBloom

  # post-transaction stateroot (pre Byzantium).
  if receipt.hasStateRoot:
    result.root = Opt.some(receipt.stateRoot)
  else:
    # 1 = success, 0 = failure.
    result.status = Opt.some(Quantity(receipt.status.uint64))

  let baseFeePerGas = header.baseFeePerGas.get(0.u256)
  let normTx = eip1559TxNormalization(tx, baseFeePerGas.truncate(GasInt))
  result.effectiveGasPrice = Quantity(normTx.gasPrice)

  if tx.txType == TxEip4844:
    result.blobGasUsed = Opt.some(Quantity(tx.versionedHashes.len.uint64 * GAS_PER_BLOB.uint64))
    result.blobGasPrice = Opt.some(getBlobBaseFee(header.excessBlobGas.get(0'u64)))

proc createAccessList*(header: Header,
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
    to      = if args.to.isSome: args.to.get
              else: generateAddress(sender, nonce)
    precompiles = activePrecompilesList(fork)

  var
    prevTracer = AccessListTracer.new(
      args.accessList.get(@[]),
      sender,
      to,
      precompiles)

  while true:
    # Retrieve the current access list to expand
    let accessList = prevTracer.accessList()

    # Set the accesslist to the last accessList
    # generated by prevTracer
    args.accessList = Opt.some(accessList)

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
        accessList: accessList,
        gasUsed: Quantity res.gasUsed,
      )

    prevTracer = tracer
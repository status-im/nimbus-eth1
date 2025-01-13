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
  std/[sequtils, algorithm],
  ./rpc_types,
  ./params,
  ../db/ledger,
  ../constants, stint,
  ../utils/utils,
  ../transaction,
  ../transaction/call_evm,
  ../core/eip4844,
  ../core/chain/forked_chain,
  ../evm/types,
  ../evm/state,
  ../evm/precompiles,
  ../evm/tracer/access_list_tracer,
  ../evm/evm_errors,
  eth/common/transaction_utils,
  ../common/common,
  web3/eth_api_types

proc calculateMedianGasPrice*(chain: ForkedChainRef): GasInt =
  const minGasPrice = 30_000_000_000.GasInt
  var prices  = newSeqOfCap[GasInt](64)
  let blk = chain.latestBlock
  for tx in blk.transactions:
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
  result = max(result, minGasPrice)

proc unsignedTx*(tx: TransactionArgs,
                 chain: ForkedChainRef,
                 defaultNonce: AccountNonce,
                 chainId: ChainId): Transaction =
  var res: Transaction

  if tx.to.isSome:
    res.to = Opt.some(tx.to.get)

  if tx.gas.isSome:
    res.gasLimit = tx.gas.get.GasInt
  else:
    res.gasLimit = 90000.GasInt

  if tx.gasPrice.isSome:
    res.gasPrice = tx.gasPrice.get.GasInt
  else:
    res.gasPrice = calculateMedianGasPrice(chain)

  if tx.value.isSome:
    res.value = tx.value.get
  else:
    res.value = 0.u256

  if tx.nonce.isSome:
    res.nonce = tx.nonce.get.AccountNonce
  else:
    res.nonce = defaultNonce

  res.payload = tx.payload
  res.chainId = chainId

  return res

proc populateTransactionObject*(tx: Transaction,
                                optionalHash: Opt[Hash32] = Opt.none(Hash32),
                                optionalNumber: Opt[uint64] = Opt.none(uint64),
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

  if tx.txType >= TxEip4844:
    result.maxFeePerBlobGas = Opt.some(tx.maxFeePerBlobGas)
    result.blobVersionedHashes = Opt.some(tx.versionedHashes)

  if tx.txType >= TxEip7702:
    result.authorizationList = Opt.some(tx.authorizationList)

proc populateBlockObject*(blockHash: Hash32,
                          blk: Block,
                          totalDifficulty: UInt256,
                          fullTx: bool,
                          withUncles: bool = false): BlockObject =
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

  if not withUncles:
    result.uncles = blk.uncles.mapIt(it.blockHash)

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
  result.withdrawals = blk.withdrawals
  result.parentBeaconBlockRoot = header.parentBeaconBlockRoot
  result.blobGasUsed = w3Qty(header.blobGasUsed)
  result.excessBlobGas = w3Qty(header.excessBlobGas)
  result.requestsHash = header.requestsHash

proc populateReceipt*(receipt: Receipt, gasUsed: GasInt, tx: Transaction,
                      txIndex: uint64, header: Header, electra: bool): ReceiptObject =
  let sender = tx.recoverSender()
  var res = ReceiptObject()
  res.transactionHash = tx.rlpHash
  res.transactionIndex = Quantity(txIndex)
  res.blockHash = header.blockHash
  res.blockNumber = Quantity(header.number)
  if sender.isSome():
    res.`from` = sender.get()
  res.to = Opt.some(tx.destination)
  res.cumulativeGasUsed = Quantity(receipt.cumulativeGasUsed)
  res.gasUsed = Quantity(gasUsed)
  res.`type` = Opt.some Quantity(receipt.receiptType)

  if tx.contractCreation and sender.isSome:
    res.contractAddress = Opt.some(tx.creationAddress(sender[]))

  for log in receipt.logs:
    # TODO: Work everywhere with either `Hash32` as topic or `array[32, byte]`
    var topics: seq[Bytes32]
    for topic in log.topics:
      topics.add (topic)

    let logObject = FilterLog(
      removed: false,
      # TODO: Not sure what is difference between logIndex and TxIndex and how
      # to calculate it.
      logIndex: Opt.some(res.transactionIndex),
      # Note: the next 4 fields cause a lot of duplication of data, but the spec
      # is what it is. Not sure if other clients actually add this.
      transactionIndex: Opt.some(res.transactionIndex),
      transactionHash: Opt.some(res.transactionHash),
      blockHash: Opt.some(res.blockHash),
      blockNumber: Opt.some(res.blockNumber),
      # The actual fields
      address: log.address,
      data: log.data,
      topics: topics
    )
    res.logs.add(logObject)

  res.logsBloom = FixedBytes[256] receipt.logsBloom

  # post-transaction stateroot (pre Byzantium).
  if receipt.hasStateRoot:
    res.root = Opt.some(receipt.stateRoot)
  else:
    # 1 = success, 0 = failure.
    res.status = Opt.some(Quantity(receipt.status.uint64))

  let baseFeePerGas = header.baseFeePerGas.get(0.u256)
  let gasPrice = effectiveGasPrice(tx, baseFeePerGas.truncate(GasInt))
  res.effectiveGasPrice = Quantity(gasPrice)

  if tx.txType == TxEip4844:
    res.blobGasUsed = Opt.some(Quantity(tx.versionedHashes.len.uint64 * GAS_PER_BLOB.uint64))
    res.blobGasPrice = Opt.some(getBlobBaseFee(header.excessBlobGas.get(0'u64), electra))

  return res

proc createAccessList*(header: Header,
                       com: CommonRef,
                       chain: ForkedChainRef,
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
    txFrame = chain.txFrame(header.blockHash)
    parent  = txFrame.getBlockHeader(header.parentHash).valueOr:
      handleError(error)
    vmState = BaseVMState.new(parent, header, com, txFrame)
    fork    = com.toEVMFork(forkDeterminationInfo(header.number, header.timestamp))
    sender  = args.sender
    # TODO: nonce should be retrieved from txPool
    nonce   = vmState.ledger.getNonce(sender)
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
      txFrame = txFrame.ctx.txFrameBegin(txFrame)
      tracer  = AccessListTracer.new(accessList, sender, to, precompiles)
      vmState = BaseVMState.new(parent, header, com, txFrame, tracer)
      res     = rpcCallEvm(args, header, vmState).valueOr:
                  txFrame.dispose()
                  handleError("failed to call evm: " & $error.code)

    txFrame.dispose()
    
    if res.isError:
      handleError("failed to apply transaction: " & res.error)

    if tracer.equal(prevTracer):
      return AccessListResult(
        accessList: accessList,
        gasUsed: Quantity res.gasUsed,
      )

    prevTracer = tracer

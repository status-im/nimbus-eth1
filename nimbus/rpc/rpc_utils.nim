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

proc toWd(wd: Withdrawal): WithdrawalObject =
  WithdrawalObject(
    index: Quantity wd.index,
    validatorIndex: Quantity wd.validatorIndex,
    address: wd.address,
    amount: Quantity wd.amount,
  )

proc toWdList(list: openArray[Withdrawal]): seq[WithdrawalObject] =
  var res = newSeqOfCap[WithdrawalObject](list.len)
  for x in list:
    res.add toWd(x)
  return res

func toWdList(x: Opt[seq[eth_types.Withdrawal]]):
                     Opt[seq[WithdrawalObject]] =
  if x.isNone: Opt.none(seq[WithdrawalObject])
  else: Opt.some(toWdList x.get)

proc populateTransactionObject*(tx: Transaction,
                                optionalHash: Opt[eth_types.Hash32] = Opt.none(eth_types.Hash32),
                                optionalNumber: Opt[eth_types.BlockNumber] = Opt.none(eth_types.BlockNumber),
                                txIndex: Opt[uint64] = Opt.none(uint64)): TransactionObject =
  var res = TransactionObject()
  res.`type` = Opt.some Quantity(tx.txType)
  res.blockHash = optionalHash
  res.blockNumber = w3Qty(optionalNumber)

  if (let sender = tx.recoverSender(); sender.isOk):
    res.`from` = sender[]
  res.gas = Quantity(tx.gasLimit)
  res.gasPrice = Quantity(tx.gasPrice)
  res.hash = tx.rlpHash
  res.input = tx.payload
  res.nonce = Quantity(tx.nonce)
  res.to = Opt.some(tx.destination)
  if txIndex.isSome:
    res.transactionIndex = Opt.some(Quantity(txIndex.get))
  res.value = tx.value
  res.v = Quantity(tx.V)
  res.r = tx.R
  res.s = tx.S
  res.maxFeePerGas = Opt.some Quantity(tx.maxFeePerGas)
  res.maxPriorityFeePerGas = Opt.some Quantity(tx.maxPriorityFeePerGas)

  if tx.txType >= TxEip2930:
    res.chainId = Opt.some(Quantity(tx.chainId))
    res.accessList = Opt.some(tx.accessList)

  if tx.txType >= TxEIP4844:
    res.maxFeePerBlobGas = Opt.some(tx.maxFeePerBlobGas)
    res.blobVersionedHashes = Opt.some(tx.versionedHashes)

  return res

proc populateBlockObject*(blockHash: Hash32,
                          blk: Block,
                          totalDifficulty: UInt256,
                          fullTx: bool,
                          isUncle = false): BlockObject =
  template header: auto = blk.header

  var res = BlockObject()
  res.number = Quantity(header.number)
  res.hash = blockHash
  res.parentHash = header.parentHash
  res.nonce = Opt.some(header.nonce)
  res.sha3Uncles = header.ommersHash
  res.logsBloom = header.logsBloom
  res.transactionsRoot = header.txRoot
  res.stateRoot = header.stateRoot
  res.receiptsRoot = header.receiptsRoot
  res.miner = header.coinbase
  res.difficulty = header.difficulty
  res.extraData = HistoricExtraData header.extraData
  res.mixHash = Hash32 header.mixHash

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(Header) - sizeof(seq[byte]) + header.extraData.len
  res.size = Quantity(size)

  res.gasLimit  = Quantity(header.gasLimit)
  res.gasUsed   = Quantity(header.gasUsed)
  res.timestamp = Quantity(header.timestamp)
  res.baseFeePerGas = header.baseFeePerGas
  res.totalDifficulty = totalDifficulty

  if not isUncle:
    res.uncles = blk.uncles.mapit(it.blockHash)

    if fullTx:
      for i, tx in blk.transactions:
        let txObj = populateTransactionObject(tx,
          Opt.some(blockHash),
          Opt.some(header.number), Opt.some(i.uint64))
        res.transactions.add txOrHash(txObj)
    else:
      for i, tx in blk.transactions:
        let txHash = rlpHash(tx)
        res.transactions.add txOrHash(txHash)

  res.withdrawalsRoot = header.withdrawalsRoot
  res.withdrawals = toWdList blk.withdrawals
  res.parentBeaconBlockRoot = header.parentBeaconBlockRoot
  res.blobGasUsed = w3Qty(header.blobGasUsed)
  res.excessBlobGas = w3Qty(header.excessBlobGas)

  return res

proc populateReceipt*(receipt: Receipt, gasUsed: GasInt, tx: Transaction,
                      txIndex: uint64, header: Header): ReceiptObject =
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
  let normTx = eip1559TxNormalization(tx, baseFeePerGas.truncate(GasInt))
  res.effectiveGasPrice = Quantity(normTx.gasPrice)

  if tx.txType == TxEip4844:
    res.blobGasUsed = Opt.some(Quantity(tx.versionedHashes.len.uint64 * GAS_PER_BLOB.uint64))
    res.blobGasPrice = Opt.some(getBlobBaseFee(header.excessBlobGas.get(0'u64)))

  return res

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
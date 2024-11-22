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
  std/[algorithm],
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

proc calculateMedianGasPrice*(chain: CoreDbRef): GasInt {.raises: [RlpError].} =
  const minGasPrice = 30_000_000_000.GasInt
  var prices  = newSeqOfCap[GasInt](64)
  let header = chain.getCanonicalHead().valueOr:
    return minGasPrice
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
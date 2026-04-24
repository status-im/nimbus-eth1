# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  std/sequtils,
  stint,
  web3/[conversions, eth_api_types],
  eth/common/[base, transaction_utils],
  stew/byteutils,
  ../common/common,
  json_rpc/rpcserver,
  ../db/storage_types,
  ../core/chain/forked_chain,
  ../core/tx_pool,
  ../beacon/web3_eth_conv,
  ../transaction,
  ../transaction/call_evm_rpc,
  ../evm/evm_errors,
  ../core/eip4844,
  ../core/pooled_txs_rlp,
  ./oracle,
  ./rpc_types,
  ./rpc_utils,
  ./filters

logScope:
  topics = "rpc"

type ServerAPIRef* = ref object
  txPool: TxPoolRef
  oracle: Oracle

const defaultTag = blockId("latest")

template com(api: ServerAPIRef): CommonRef =
  api.txPool.com

template chain(api: ServerAPIRef): ForkedChainRef =
  api.txPool.chain

func newServerAPI*(txPool: TxPoolRef): ServerAPIRef =
  ServerAPIRef(
    txPool: txPool,
    oracle: Oracle.new(txPool.chain),
  )

proc getTotalDifficulty*(api: ServerAPIRef, blockHash: Hash32, header: Header): Opt[UInt256] =
  api.txPool.chain.getTotalDifficulty(blockHash, header)

const emptyDbAccount = CoreDbAccount(
  nonce: EMPTY_ACCOUNT.nonce, balance: EMPTY_ACCOUNT.balance, codeHash: EMPTY_CODE_HASH
)

proc getProof*(
    txFrame: CoreDbTxRef, address: Address, slots: seq[UInt256]
): ProofResponse {.raises: [ValueError].} =
  var
    accPath = address.computeAccPath
    accountProof = txFrame.proof(accPath).valueOr:
      raise newException(ValueError, "Failed to get account proof: " & $error)
    accExists = accountProof[1]
    storage = slots.mapIt(StorageProof(key: it))

  if accExists:
    var
      acc = txFrame.fetchAccount(accPath).valueOr(emptyDbAccount)
      storageRoot = txFrame.fetchStorageRoot(accPath).valueOr(emptyRoot)
      slotKeys = slots.mapIt(computeSlotKey(it))
      slotProofs = txFrame.slotProofs(accPath, slotKeys).valueOr:
        raise newException(ValueError, "Failed to get slot proof: " & $error)

    for i, item in storage.mpairs():
      item.value = txFrame.fetchSlot(accPath, slotKeys[i]).valueOr(0.u256)
      item.proof = seq[RlpEncodedBytes](move(slotProofs[i]))

    ProofResponse(
      address: address,
      accountProof: seq[RlpEncodedBytes](move(accountProof[0])),
      balance: acc.balance,
      nonce: w3Qty(acc.nonce),
      codeHash: acc.codeHash,
      storageHash: storageRoot,
      storageProof: storage,
    )
  else:
    ProofResponse(
      address: address,
      accountProof: seq[RlpEncodedBytes](move(accountProof[0])),
      storageProof: storage,
    )

proc headerFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[Header, string] =
  api.chain.headerFromTag(blockTag)

proc headerFromTag(api: ServerAPIRef, blockTag: Opt[BlockTag]): Result[Header, string] =
  let blockId = blockTag.get(defaultTag)
  api.headerFromTag(blockId)

proc frameFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[CoreDbTxRef, string] =
  # TODO avoid loading full header if hash is given

  let
    header = ?api.headerFromTag(blockTag)

  if header.number < api.chain.baseNumber:
    return err("Historical data not available")

  # TODO maybe use a new frame derived from txFrame, to protect against abuse?
  ok api.chain.txFrame(header)

proc blockFromTag(api: ServerAPIRef, blockTag: BlockTag, noHash: bool = false): Result[Block, string] =
  api.chain.blockFromTag(blockTag, noHash)

proc setupServerAPI*(api: ServerAPIRef, server: RpcServer, am: ref AccountsManager) =
  server.rpc("eth_getBalance") do(data: Address, blockTag: BlockTag) -> UInt256:
    ## Returns the balance of the account of given address.
    let
      txFrame = api.frameFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
      acc = txFrame.fetchAccount(address.computeAccPath).valueOr(emptyDbAccount)
    acc.balance

  server.rpc("eth_getStorageAt") do(
    data: Address, slot: UInt256, blockTag: BlockTag
  ) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    let
      txFrame = api.frameFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
      accPath = address.computeAccPath
      slotKey = computeSlotKey(slot)
      value = txFrame.fetchSlot(accPath, slotKey).valueOr(0.u256)
    value.to(Bytes32)

  server.rpc("eth_getTransactionCount") do(
    data: Address, blockTag: BlockTag
  ) -> Quantity:
    ## Returns the number of transactions ak.s. nonce sent from an address.
    let
      txFrame = api.frameFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
      accPath = address.computeAccPath
      acc = txFrame.fetchAccount(accPath).valueOr(emptyDbAccount)
      nonce = acc.nonce
    Quantity(nonce)

  server.rpc("eth_blockNumber") do() -> Quantity:
    ## Returns integer of the current block number the client is on.
    Quantity(api.chain.latestNumber)

  server.rpc("eth_chainId") do() -> UInt256:
    return api.com.chainId

  server.rpc("eth_getCode") do(data: Address, blockTag: BlockTag) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## blockTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      txFrame = api.frameFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
      accPath = address.computeAccPath
      acc = txFrame.fetchAccount(accPath).valueOr(emptyDbAccount)

    txFrame.getCodeByHash(acc.codeHash).valueOr(@[])

  server.rpc("eth_getBlockByHash") do(
    data: Hash32, fullTransactions: bool
  ) -> BlockObject:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let blockHash = data

    let blk = api.chain.blockByHash(blockHash).valueOr:
      return nil

    return populateBlockObject(
      blockHash, blk, api.getTotalDifficulty(blockHash, blk.header), fullTransactions
    )

  server.rpc("eth_getBlockByNumber") do(
    blockTag: BlockTag, fullTransactions: bool
  ) -> BlockObject:
    ## Returns information about a block by block number.
    ##
    ## blockTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let blk = api.blockFromTag(blockTag, noHash = true).valueOr:
      return nil

    let blockHash = blk.header.computeBlockHash
    return populateBlockObject(
      blockHash, blk, api.getTotalDifficulty(blockHash, blk.header), fullTransactions
    )

  server.rpc("eth_syncing") do() -> SyncingStatus:
    ## Returns SyncObject or false when not syncing.
    let (start, current, target) = api.com.beaconSyncerProgress()
    if start == 0 and current == 0 and target == 0:
      return SyncingStatus(syncing: false)
    else:
      let sync = SyncObject(
        startingBlock: Quantity(start),
        currentBlock: Quantity(current),
        highestBlock: Quantity(target),
      )
      return SyncingStatus(syncing: true, syncObject: sync)

  proc getLogsForBlock(
      chain: ForkedChainRef, header: Header, opts: FilterOptions
  ): Opt[seq[FilterLog]] =
    if headerBloomFilter(header, opts.address, opts.topics):
      let
        blkHash = header.computeBlockHash
        blockBody = chain.blockBodyByHash(blkHash).valueOr:
          return Opt.none(seq[FilterLog])
        receipts = chain.receiptsByBlockHash(blkHash).valueOr:
          return Opt.none(seq[FilterLog])
        cachedHashes = chain.memoryTxHashesForBlock(blkHash)
      # Note: this will hit assertion error if number of block transactions
      # do not match block receipts.
      # Although this is fine as number of receipts should always match number
      # of transactions
      if blockBody.transactions.len != receipts.len:
        warn "Transactions and receipts length mismatch",
          number = header.number, hash = blkHash.short,
          txs = blockBody.transactions.len, receipts = receipts.len
        return Opt.none(seq[FilterLog])
      let logs = deriveLogs(header, blockBody.transactions, receipts, opts, cachedHashes)
      return Opt.some(logs)
    else:
      return Opt.some(newSeq[FilterLog](0))

  proc getLogsForRange(
      chain: ForkedChainRef,
      start: base.BlockNumber,
      finish: base.BlockNumber,
      opts: FilterOptions,
  ): seq[FilterLog] =
    var
      logs = newSeq[FilterLog]()
      blockNum = start

    while blockNum <= finish:
      let
        header = chain.headerByNumber(blockNum).valueOr:
          return logs
        filtered = chain.getLogsForBlock(header, opts).valueOr:
          return logs
      logs.add(filtered)
      blockNum = blockNum + 1
    return logs

  server.rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[FilterLog]:
    ## filterOptions: settings for this filter.
    ## Returns a list of all logs matching a given filter object.
    ## TODO: Current implementation is pretty naive and not efficient
    ## as it requires to fetch all transactions and all receipts from database.
    ## Other clients (Geth):
    ## - Store logs related data in receipts.
    ## - Have separate indexes for Logs in given block
    ## Both of those changes require improvements to the way how we keep our data
    ## in Nimbus.
    if filterOptions.blockHash.isSome():
      if filterOptions.fromBlock.isSome() or filterOptions.toBlock.isSome():
        raise (ref ApplicationError)(code: -32602, msg: "invalid argument 0: cannot specify both BlockHash and FromBlock/ToBlock, choose one or the other",)
      let
        hash = filterOptions.blockHash.expect("blockHash")
        header = api.chain.headerByHash(hash).valueOr:
          raise newException(ValueError, "Block not found")
        logs = getLogsForBlock(api.chain, header, filterOptions).valueOr:
          raise newException(ValueError, "getLogsForBlock error")
      return logs
    else:
      # TODO: do something smarter with tags. It would be the best if
      # tag would be an enum (Earliest, Latest, Pending, Number), and all operations
      # would operate on this enum instead of raw strings. This change would need
      # to be done on every endpoint to be consistent.
      if filterOptions.toBlock.isSome() and
          filterOptions.toBlock.get().kind == bidNumber and
          base.BlockNumber(filterOptions.toBlock.get().number) > api.chain.latestHeader.number:
        raise (ref ApplicationError)(code: -32602,msg: "block range extends beyond current head block",)

      let
        blockFrom = api.headerFromTag(filterOptions.fromBlock.get(defaultTag)).valueOr:
          raise newException(ValueError, "Block not found")
        blockTo = api.headerFromTag(filterOptions.toBlock.get(defaultTag)).valueOr:
          raise newException(ValueError, "Block not found")

      if blockFrom.number > blockTo.number:
        raise (ref ApplicationError)(code: -32602, msg: "invalid block range params")

      return api.chain.getLogsForRange(blockFrom.number, blockTo.number, filterOptions)

  server.rpc("eth_sendRawTransaction") do(txBytes: seq[byte]) -> Hash32:
    ## Creates new message call transaction or a contract creation for signed transactions.
    ##
    ## data: the signed transaction data.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    let
      pooledTx = decodePooledTx(txBytes)
      txHash = computeRlpHash(pooledTx.tx)
      sender = pooledTx.tx.recoverSender().get()

    api.txPool.addTx(pooledTx).isOkOr:
      raise newException(ValueError, $error)

    txHash

  server.rpc("eth_call") do(args: TransactionArgs, blockTag: BlockTag) -> seq[byte]:
    ## Executes a new message call immediately without creating a transaction on the block chain.
    ##
    ## call: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the return value of executed contract.
    let
      header = api.headerFromTag(blockTag).valueOr:
        raise newException(ValueError, "Block not found")
      headerHash = header.computeBlockHash
      txFrame = api.chain.txFrame(headerHash)
      res = rpcCallEvm(args, header, headerHash, api.com, txFrame).valueOr:
        raise newException(ValueError, "rpcCallEvm error: " & $error.code)
    res.output

  server.rpc("eth_getTransactionReceipt") do(data: Hash32) -> ReceiptObject:
    ## Returns the receipt of a transaction by transaction hash.
    ##
    ## data: Hash of a transaction.
    ## Returns ReceiptObject or nil when no receipt was found.
    let
      txHash = data
      (blockHash, txid) = api.chain.txDetailsByTxHash(txHash).valueOr:
        return nil
      blk = api.chain.blockByHash(blockHash).valueOr:
        return nil
      receipts = api.chain.receiptsByBlockHash(blockHash).valueOr:
        return nil

    var prevGasUsed = 0'u64
    for idx, receipt in receipts:
      let gasUsed = receipt.cumulativeGasUsed - prevGasUsed
      prevGasUsed = receipt.cumulativeGasUsed

      if txid == uint64(idx):
        return populateReceipt(receipt, gasUsed, blk.transactions[txid], txid, blk.header, api.com)

  server.rpc("eth_estimateGas") do(args: TransactionArgs) -> Quantity:
    ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
    ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
    ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
    ##
    ## args: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the amount of gas used.
    let
      header = api.headerFromTag(blockId("latest")).valueOr:
        raise newException(ValueError, "Block not found")
      headerHash = header.computeBlockHash
      txFrame = api.chain.txFrame(headerHash)
      # TODO: change 0 to configureable gas cap
      gasUsed = rpcEstimateGas(args, header, headerHash, api.com, txFrame, DEFAULT_RPC_GAS_CAP).valueOr:
        let data = Opt.some(JrpcConv.encode(error[1].output.to0xHex()).JsonString)
        raise (ref ApplicationError)(
          code: 3,
          msg: $error[1].error,
          data: data,
        )
    Quantity(gasUsed)

  server.rpc("eth_gasPrice") do() -> Quantity:
    ## Returns an integer of the current gas price in wei.
    w3Qty(calculateMedianGasPrice(api.chain).uint64)

  server.rpc("eth_accounts") do() -> seq[Address]:
    ## Returns a list of addresses owned by client.
    result = newSeqOfCap[Address](am[].numAccounts)
    for k in am[].addresses:
      result.add k

  server.rpc("eth_getBlockTransactionCountByHash") do(data: Hash32) -> Quantity:
    ## Returns the number of transactions in a block from a block matching the given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    let blk = api.chain.blockByHash(data).valueOr:
      raise newException(ValueError, "Block not found")

    Quantity(blk.transactions.len)

  server.rpc("eth_getBlockTransactionCountByNumber") do(
    blockTag: BlockTag
  ) -> Quantity:
    ## Returns the number of transactions in a block from a block matching the given block number.
    ##
    ## blockTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the number of transactions in this block.
    let blk = api.blockFromTag(blockTag, noHash = true).valueOr:
      raise newException(ValueError, "Block not found: " & error)

    Quantity(blk.transactions.len)

  server.rpc("eth_getUncleCountByBlockHash") do(data: Hash32) -> Quantity:
    ## Returns the number of uncles in a block from a block matching the given block hash.
    ##
    ## data: hash of a block.
    ## Returns integer of the number of uncles in this block.
    let blk = api.chain.blockByHash(data).valueOr:
      raise newException(ValueError, "Block not found")

    Quantity(blk.uncles.len)

  server.rpc("eth_getUncleCountByBlockNumber") do(blockTag: BlockTag) -> Quantity:
    ## Returns the number of uncles in a block from a block matching the given block number.
    ##
    ## blockTag: integer of a block number, or the string "latest", see the default block parameter.
    ## Returns integer of the number of uncles in this block.
    let blk = api.blockFromTag(blockTag, noHash = true).valueOr:
      raise newException(ValueError, "Block not found: " & error)

    Quantity(blk.uncles.len)

  template sign(privateKey: PrivateKey, message: string): seq[byte] =
    # message length encoded as ASCII representation of decimal
    let msgData = "\x19Ethereum Signed Message:\n" & $message.len & message
    @(sign(privateKey, msgData.toBytes()).toRaw())

  server.rpc("eth_sign") do(data: Address, message: seq[byte]) -> seq[byte]:
    ## The sign method calculates an Ethereum specific signature with: sign(keccak256("\x19Ethereum Signed Message:\n" + len(message) + message))).
    ## By adding a prefix to the message makes the calculated signature recognisable as an Ethereum specific signature.
    ## This prevents misuse where a malicious DApp can sign arbitrary data (e.g. transaction) and use the signature to impersonate the victim.
    ## Note the address to sign with must be unlocked.
    ##
    ## data: address.
    ## message: message to sign.
    ## Returns signature.
    let
      address = data
      acc = am[].getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")
    sign(acc.privateKey, cast[string](message))

  server.rpc("eth_signTransaction") do(data: TransactionArgs) -> seq[byte]:
    ## Signs a transaction that can be submitted to the network at a later time using with
    ## eth_sendRawTransaction
    let
      address = data.`from`.get()
      acc = am[].getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      txFrame = api.frameFromTag(blockId("latest")).valueOr:
        raise newException(ValueError, "Latest Block not found")
      accRec = txFrame.fetchAccount(address.computeAccPath).valueOr(emptyDbAccount)
      tx = unsignedTx(data, api.chain, accRec.nonce + 1, api.com.chainId)
      eip155 = api.com.isEIP155(api.chain.latestNumber)
      signedTx = signTransaction(tx, acc.privateKey, eip155)
    return rlp.encode(signedTx)

  server.rpc("eth_sendTransaction") do(data: TransactionArgs) -> Hash32:
    ## Creates new message call transaction or a contract creation, if the data field contains code.
    ##
    ## obj: the transaction object.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    let
      address = data.`from`.get()
      acc = am[].getAccount(address).tryGet()

    if not acc.unlocked:
      raise newException(ValueError, "Account locked, please unlock it first")

    let
      txFrame = api.frameFromTag(blockId("latest")).valueOr:
        raise newException(ValueError, "Latest Block not found")
      accRec = txFrame.fetchAccount(address.computeAccPath).valueOr(emptyDbAccount)

      tx = unsignedTx(data, api.chain, accRec.nonce + 1, api.com.chainId)
      eip155 = api.com.isEIP155(api.chain.latestNumber)
      signedTx = signTransaction(tx, acc.privateKey, eip155)
      blobsBundle =
        if signedTx.txType == TxEip4844:
          if data.blobs.isNone or data.commitments.isNone or data.proofs.isNone:
            raise newException(ValueError, "EIP-4844 transaction needs blobs")
          if data.blobs.get.len != signedTx.versionedHashes.len:
            raise newException(ValueError, "Incorrect number of blobs")
          if data.commitments.get.len != signedTx.versionedHashes.len:
            raise newException(ValueError, "Incorrect number of commitments")
          if data.proofs.get.len != signedTx.versionedHashes.len:
            raise newException(ValueError, "Incorrect number of proofs")
          BlobsBundle(
            blobs: data.blobs.get,
            commitments: data.commitments.get,
            proofs: data.proofs.get,
          )
        else:
          if data.blobs.isSome or data.commitments.isSome or data.proofs.isSome:
            raise newException(ValueError, "Blobs require EIP-4844 transaction")
          nil
      pooledTx = PooledTransaction(tx: signedTx, blobsBundle: blobsBundle)

    api.txPool.addTx(pooledTx).isOkOr:
      raise newException(ValueError, $error)

    let txHash = computeRlpHash(signedTx)

    txHash

  server.rpc("eth_getTransactionByHash") do(data: Hash32) -> TransactionObject:
    ## Returns the information about a transaction requested by transaction hash.
    ##
    ## data: hash of a transaction.
    ## Returns requested transaction information.
    let
      txHash = data
      res = api.txPool.getItem(txHash)
    if res.isOk:
      return populateTransactionObject(res.get().tx, Opt.none(Hash32), Opt.none(uint64))

    let
      (blockHash, txId) = api.chain.txDetailsByTxHash(txHash).valueOr:
        return nil
      blk = api.chain.blockByHash(blockHash).valueOr:
        return nil

    if blk.transactions.len <= int(txId):
      return nil

    return populateTransactionObject(
      blk.transactions[txId],
      Opt.some(blockHash),
      Opt.some(blk.header.number),
      Opt.some(blk.header.timestamp),
      Opt.some(txId),
    )

  server.rpc("eth_getTransactionByBlockHashAndIndex") do(
    data: Hash32, quantity: Quantity
  ) -> TransactionObject:
    ## Returns information about a transaction by block hash and transaction index position.
    ##
    ## data: hash of a block.
    ## quantity: integer of the transaction index position.
    ## Returns  requested transaction information.
    let index = uint64(quantity)
    let blk = api.chain.blockByHash(data).valueOr:
      return nil

    if index >= uint64(blk.transactions.len):
      return nil

    populateTransactionObject(
      blk.transactions[index],
      Opt.some(data),
      Opt.some(blk.header.number),
      Opt.some(blk.header.timestamp),
      Opt.some(index),
    )

  server.rpc("eth_getTransactionByBlockNumberAndIndex") do(
    quantityTag: BlockTag, quantity: Quantity
  ) -> TransactionObject:
    ## Returns information about a transaction by block number and transaction index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the transaction index position.
    ## NOTE : "pending" blockTag is not supported.
    let index = uint64(quantity)
    let blk = api.blockFromTag(quantityTag, noHash = true).valueOr:
      return nil

    if index >= uint64(blk.transactions.len):
      return nil

    populateTransactionObject(
      blk.transactions[index],
      Opt.some(blk.header.computeBlockHash),
      Opt.some(blk.header.number),
      Opt.some(blk.header.timestamp),
      Opt.some(index),
    )

  server.rpc("eth_getProof") do(
    data: Address, slots: seq[UInt256], quantityTag: BlockTag
  ) -> ProofResponse:
    ## Returns information about an account and storage slots (if the account is a contract
    ## and the slots are requested) along with account and storage proofs which prove the
    ## existence of the values in the state.
    ## See spec here: https://eips.ethereum.org/EIPS/eip-1186
    ##
    ## data: address of the account.
    ## slots: integers of the positions in the storage to return with storage proofs.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the proof response containing the account, account proof and storage proof
    let
      txFrame = api.frameFromTag(quantityTag).valueOr:
        raise newException(ValueError, error)
    getProof(txFrame, data, slots)

  server.rpc("eth_getBlockReceipts") do(
    quantityTag: BlockTag
  ) -> Opt[seq[ReceiptObject]]:
    ## Returns the receipts of a block.
    if quantityTag.kind == bidHash and quantityTag.requireCanonical:
      raise newException(ValueError,
        "requireCanonical is a pre-merge concept and is not supported")

    let
      blk = api.blockFromTag(quantityTag).valueOr:
        return Opt.none(seq[ReceiptObject])
      blkHash = blk.header.computeBlockHash
      receipts = api.chain.receiptsByBlockHash(blkHash).valueOr:
        return Opt.none(seq[ReceiptObject])

    if blk.transactions.len == 0:
      return Opt.some(newSeq[ReceiptObject]())

    var
      prevGasUsed = GasInt(0)
      recs: seq[ReceiptObject]
      index = 0'u64

    try:
      for receipt in receipts:
        let gasUsed = receipt.cumulativeGasUsed - prevGasUsed
        prevGasUsed = receipt.cumulativeGasUsed
        recs.add populateReceipt(receipt, gasUsed, blk.transactions[index], index, blk.header, api.com)
        inc index
      return Opt.some(recs)
    except CatchableError:
      return Opt.none(seq[ReceiptObject])

  server.rpc("eth_createAccessList") do(
    args: TransactionArgs, quantityTag: BlockTag
  ) -> AccessListResult:
    ## Generates an access list for a transaction.
    try:
      let header = api.headerFromTag(quantityTag).valueOr:
        raise newException(ValueError, "Block not found")
      return createAccessList(header, api.com, api.chain, args)
    except CatchableError as exc:
      return AccessListResult(error: Opt.some("createAccessList error: " & exc.msg))

  server.rpc("eth_blobBaseFee") do() -> Quantity:
    ## Returns the base fee per blob gas in wei.
    let header = api.headerFromTag(blockId("latest")).valueOr:
      raise newException(ValueError, "Block not found")
    if header.excessBlobGas.isNone:
      raise newException(ValueError, "excessBlobGas missing from latest header")
    let blobBaseFee =
      getBlobBaseFee(header.excessBlobGas.get, api.com, api.com.toEVMFork(header))
    if blobBaseFee > high(uint64).u256:
      raise newException(ValueError, "blobBaseFee is bigger than uint64.max")
    return w3Qty blobBaseFee.truncate(uint64)

  server.rpc("eth_getUncleByBlockHashAndIndex") do(
    data: Hash32, quantity: Quantity
  ) -> BlockObject:
    ## Returns information about a uncle of a block by hash and uncle index position.
    ##
    ## data: hash of block.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let index = uint64(quantity)
    let blk = api.chain.blockByHash(data).valueOr:
      return nil

    if index < 0 or index >= blk.uncles.len.uint64:
      return nil

    let
      uncle = api.chain.blockByHash(blk.uncles[index].computeBlockHash).valueOr:
        return nil
      uncleHash = uncle.header.computeBlockHash

    return populateBlockObject(
      uncleHash, uncle, api.getTotalDifficulty(uncleHash, uncle.header), false, true
    )

  server.rpc("eth_getUncleByBlockNumberAndIndex") do(
    quantityTag: BlockTag, quantity: Quantity
  ) -> BlockObject:
    # Returns information about a uncle of a block by number and uncle index position.
    ##
    ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## quantity: the uncle's index position.
    ## Returns BlockObject or nil when no block was found.
    let index = uint64(quantity)
    let blk = api.blockFromTag(quantityTag).valueOr:
      return nil

    if index < 0 or index >= blk.uncles.len.uint64:
      return nil

    let
      uncle = api.chain.blockByHash(blk.uncles[index].computeBlockHash).valueOr:
        return nil
      uncleHash = uncle.header.computeBlockHash

    return populateBlockObject(
      uncleHash, uncle, api.getTotalDifficulty(uncleHash, uncle.header), false, true
    )

  server.rpc("eth_config") do() -> EthConfigObject:
    ## Returns the current, next and last configuration
    ## Doesn't work pre-shangai
    ## https://eips.ethereum.org/EIPS/eip-7910
    let currentFork = api.com.toHardFork(api.chain.latestHeader.forkDeterminationInfo)

    if currentFork < Shanghai:
      return nil

    let
      nextFork = api.com.nextFork(currentFork)
      lastFork = api.com.lastFork(currentFork)

    return api.com.getEthConfigObject(api.chain, currentFork, nextFork, lastFork)

  server.rpc("eth_getBlockAccessList") do(quantityTag: BlockTag) -> Opt[BlockAccessList]:
    ## Returns the block access list by block number, tag or block hash.
    ##

    let header = api.chain.headerFromTag(quantityTag).valueOr:
      raise newException(ValueError, error)

    if not api.com.isAmsterdamOrLater(header.timestamp):
      raise newException(ValueError, "Block access list not available for pre-Amsterdam blocks")

    let bal = api.chain.getBlockAccessList(header.computeRlpHash()).valueOr:
      if header.number <= api.chain.resolvedFinNumber:
        # This block is finalized so if the bal is missing it means it was pruned.
        raise newException(ValueError, "Pruned history unavailable")
      else:
        return Opt.none(BlockAccessList)

    Opt.some(bal)

  server.rpc("eth_feeHistory") do(
    blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
  ) -> FeeHistoryResult:
    api.oracle.feeHistory(blockCount.uint64, newestBlock, rewardPercentiles.get(@[])).valueOr:
      raise newException(ValueError, error)

  server.rpc("eth_maxPriorityFeePerGas") do() -> Quantity:
    w3Qty(calculateMedianMaxPriorityFeePerGas(api.chain).uint64)

  server.rpc("eth_getStorageValues") do(request: StorageValuesRequest, blockTag: BlockTag) -> StorageValuesResponse:
    let
      txFrame = api.frameFromTag(blockTag).valueOr:
        raise newException(ValueError, error)

    var res: StorageObject
    for req in request.list:
      let accPath = req.address.computeAccPath
      res.address = req.address
      res.data.setLen(req.data.len)
      for i, slot in req.data:
        let
          slotKey = computeSlotKey(slot)
          value = txFrame.fetchSlot(accPath, slotKey).valueOr(0.u256)
        res.data[i] = value.to(Bytes32)
      result.list.add(move(res))

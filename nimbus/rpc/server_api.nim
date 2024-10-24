# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  stint,
  web3/[conversions, eth_api_types],
  eth/common/base,
  ../common/common,
  json_rpc/rpcserver,
  ../db/ledger,
  ../core/chain/forked_chain,
  ../core/tx_pool,
  ../beacon/web3_eth_conv,
  ../transaction,
  ../transaction/call_evm,
  ../evm/evm_errors,
  ./rpc_types,
  ./rpc_utils,
  ./filters,
  ./server_api_helpers

type
  ServerAPIRef* = ref object
    com: CommonRef
    chain: ForkedChainRef
    txPool: TxPoolRef

const
  defaultTag = blockId("latest")

func newServerAPI*(c: ForkedChainRef, t: TxPoolRef): ServerAPIRef =
  ServerAPIRef(
    com: c.com,
    chain: c,
    txPool: t
  )

proc headerFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[Header, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest": return ok(api.chain.latestHeader)
    else:
      return err("Unsupported block tag " & tag)
  else:
    let blockNum = base.BlockNumber blockTag.number
    return api.chain.headerByNumber(blockNum)

proc headerFromTag(api: ServerAPIRef, blockTag: Opt[BlockTag]): Result[Header, string] =
  let blockId = blockTag.get(defaultTag)
  api.headerFromTag(blockId)

proc ledgerFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[LedgerRef, string] =
  let header = ?api.headerFromTag(blockTag)
  if api.chain.stateReady(header):
    ok(LedgerRef.init(api.com.db, header.stateRoot))
  else:
    # TODO: Replay state?
    err("Block state not ready")

proc blockFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[Block, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest":
      return ok(api.chain.latestBlock)
    else:
      return err("Unsupported block tag " & tag)
  else:
    let blockNum = base.BlockNumber blockTag.number
    return api.chain.blockByNumber(blockNum)

proc setupServerAPI*(api: ServerAPIRef, server: RpcServer) =
  server.rpc("eth_getBalance") do(data: Address, blockTag: BlockTag) -> UInt256:
    ## Returns the balance of the account of given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
    ledger.getBalance(address)

  server.rpc("eth_getStorageAt") do(data: Address, slot: UInt256, blockTag: BlockTag) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
      value   = ledger.getStorage(address, slot)
    value.to(Bytes32)

  server.rpc("eth_getTransactionCount") do(data: Address, blockTag: BlockTag) -> Web3Quantity:
    ## Returns the number of transactions ak.s. nonce sent from an address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
      nonce   = ledger.getNonce(address)
    Quantity(nonce)

  server.rpc("eth_blockNumber") do() -> Web3Quantity:
    ## Returns integer of the current block number the client is on.
    Quantity(api.chain.latestNumber)

  server.rpc("eth_chainId") do() -> Web3Quantity:
    return Quantity(distinctBase(api.com.chainId))

  server.rpc("eth_getCode") do(data: Address, blockTag: BlockTag) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## blockTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = data
    ledger.getCode(address).bytes()

  server.rpc("eth_getBlockByHash") do(data: Hash32, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let blockHash = data

    let blk = api.chain.blockByHash(blockHash).valueOr:
      return nil

    return populateBlockObject(blockHash, blk, fullTransactions)

  server.rpc("eth_getBlockByNumber") do(blockTag: BlockTag, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by block number.
    ##
    ## blockTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let blk = api.blockFromTag(blockTag).valueOr:
      return nil

    let blockHash = blk.header.blockHash
    return populateBlockObject(blockHash, blk, fullTransactions)

  server.rpc("eth_syncing") do() -> SyncingStatus:
    ## Returns SyncObject or false when not syncing.
    if api.com.syncState != Waiting:
      let sync = SyncObject(
        startingBlock: Quantity(api.com.syncStart),
        currentBlock : Quantity(api.com.syncCurrent),
        highestBlock : Quantity(api.com.syncHighest)
      )
      return SyncingStatus(syncing: true, syncObject: sync)
    else:
      return SyncingStatus(syncing: false)

  proc getLogsForBlock(
      chain: ForkedChainRef,
      header: Header,
      opts: FilterOptions): seq[FilterLog]
        {.gcsafe, raises: [RlpError].} =
    if headerBloomFilter(header, opts.address, opts.topics):
      let
        receipts = chain.db.getReceipts(header.receiptsRoot)
        txs = chain.db.getTransactions(header.txRoot)
      # Note: this will hit assertion error if number of block transactions
      # do not match block receipts.
      # Although this is fine as number of receipts should always match number
      # of transactions
      let logs = deriveLogs(header, txs, receipts)
      let filteredLogs = filterLogs(logs, opts.address, opts.topics)
      return filteredLogs
    else:
      return @[]

  proc getLogsForRange(
      chain: ForkedChainRef,
      start: base.BlockNumber,
      finish: base.BlockNumber,
      opts: FilterOptions): seq[FilterLog]
        {.gcsafe, raises: [RlpError].} =
    var
      logs = newSeq[FilterLog]()
      blockNum = start

    while blockNum <= finish:
      let
        header = chain.headerByNumber(blockNum).valueOr:
                return logs
        filtered = chain.getLogsForBlock(header, opts)
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
      let
        hash = filterOptions.blockHash.expect("blockHash")
        header = api.chain.headerByHash(hash).valueOr:
          raise newException(ValueError, "Block not found")
      return getLogsForBlock(api.chain, header, filterOptions)
    else:
      # TODO: do something smarter with tags. It would be the best if
      # tag would be an enum (Earliest, Latest, Pending, Number), and all operations
      # would operate on this enum instead of raw strings. This change would need
      # to be done on every endpoint to be consistent.
      let
        blockFrom = api.headerFromTag(filterOptions.fromBlock).valueOr:
          raise newException(ValueError, "Block not found")
        blockTo = api.headerFromTag(filterOptions.toBlock).valueOr:
          raise newException(ValueError, "Block not found")

      # Note: if fromHeader.number > toHeader.number, no logs will be
      # returned. This is consistent with, what other ethereum clients return
      return api.chain.getLogsForRange(
        blockFrom.number,
        blockTo.number,
        filterOptions
      )

  server.rpc("eth_sendRawTransaction") do(txBytes: seq[byte]) -> Hash32:
    ## Creates new message call transaction or a contract creation for signed transactions.
    ##
    ## data: the signed transaction data.
    ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
    ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
    let
      pooledTx = decodePooledTx(txBytes)
      txHash   = rlpHash(pooledTx)

    api.txPool.add(pooledTx)
    let res = api.txPool.inPoolAndReason(txHash)
    if res.isErr:
      raise newException(ValueError, res.error)
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
      res    = rpcCallEvm(args, header, api.com).valueOr:
                 raise newException(ValueError, "rpcCallEvm error: " & $error.code)
    res.output

  server.rpc("eth_getTransactionReceipt") do(data: Hash32) -> ReceiptObject:
    ## Returns the receipt of a transaction by transaction hash.
    ##
    ## data: Hash of a transaction.
    ## Returns ReceiptObject or nil when no receipt was found.
    var
      idx = 0'u64
      prevGasUsed = GasInt(0)

    let
      txHash = data
      (blockhash, txid) = api.chain.txRecords(txHash)

    if blockhash == zeroHash32:
      # Receipt in database
      let txDetails = api.chain.db.getTransactionKey(txHash)
      if txDetails.index < 0:
        return nil

      let header = api.chain.headerByNumber(txDetails.blockNumber).valueOr:
        raise newException(ValueError, "Block not found")
      var tx: Transaction
      if not api.chain.db.getTransactionByIndex(header.txRoot, uint16(txDetails.index), tx):
        return nil

      for receipt in api.chain.db.getReceipts(header.receiptsRoot):
        let gasUsed = receipt.cumulativeGasUsed - prevGasUsed
        prevGasUsed = receipt.cumulativeGasUsed
        if idx == txDetails.index:
          return populateReceipt(receipt, gasUsed, tx, txDetails.index, header)
        idx.inc
    else:
      # Receipt in memory
      let blkdesc = api.chain.memoryBlock(blockhash)

      while idx <= txid:
        let receipt = blkdesc.receipts[idx]
        let gasUsed = receipt.cumulativeGasUsed - prevGasUsed
        prevGasUsed = receipt.cumulativeGasUsed

        if txid == idx:
          return populateReceipt(receipt, gasUsed, blkdesc.blk.transactions[txid], txid, blkdesc.blk.header)

        idx.inc

  server.rpc("eth_estimateGas") do(args: TransactionArgs) -> Web3Quantity:
    ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
    ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
    ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
    ##
    ## args: the transaction call object.
    ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the amount of gas used.
    let
      header   = api.headerFromTag(blockId("latest")).valueOr:
        raise newException(ValueError, "Block not found")
      gasUsed  = rpcEstimateGas(args, header, api.chain.com, DEFAULT_RPC_GAS_CAP).valueOr:
        raise newException(ValueError, "rpcEstimateGas error: " & $error.code)
    Quantity(gasUsed)

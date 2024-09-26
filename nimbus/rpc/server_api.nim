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
  web3/conversions,
  json_rpc/rpcserver,
  ../common,
  ../db/ledger,
  ../core/chain/forked_chain,
  ../beacon/web3_eth_conv,
  ../transaction/call_evm,
  ../evm/evm_errors,
  ./rpc_types,
  ./filters,
  ./server_api_helpers

type
  ServerAPIRef = ref object
    com: CommonRef
    chain: ForkedChainRef

const
  defaultTag = blockId("latest")

func newServerAPI*(c: ForkedChainRef): ServerAPIRef =
  ServerAPIRef(
    com: c.com,
    chain: c,
  )

proc headerFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[common.BlockHeader, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest": return ok(api.chain.latestHeader)
    else:
      return err("Unsupported block tag " & tag)
  else:
    let blockNum = common.BlockNumber blockTag.number
    return api.chain.headerByNumber(blockNum)

proc headerFromTag(api: ServerAPIRef, blockTag: Opt[BlockTag]): Result[common.BlockHeader, string] =
  let blockId = blockTag.get(defaultTag)
  api.headerFromTag(blockId)

proc ledgerFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[LedgerRef, string] =
  let header = ?api.headerFromTag(blockTag)
  if api.chain.stateReady(header):
    ok(LedgerRef.init(api.com.db, header.stateRoot))
  else:
    # TODO: Replay state?
    err("Block state not ready")

func blockFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[EthBlock, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest": return ok(api.chain.latestBlock)
    else:
      return err("Unsupported block tag " & tag)
  else:
    let blockNum = common.BlockNumber blockTag.number
    return api.chain.blockByNumber(blockNum)

proc setupServerAPI*(api: ServerAPIRef, server: RpcServer) =
  server.rpc("eth_getBalance") do(data: Web3Address, blockTag: BlockTag) -> UInt256:
    ## Returns the balance of the account of given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
    result = ledger.getBalance(address)

  server.rpc("eth_getStorageAt") do(data: Web3Address, slot: UInt256, blockTag: BlockTag) -> Web3FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
      value   = ledger.getStorage(address, slot)
    result = w3FixedBytes value

  server.rpc("eth_getTransactionCount") do(data: Web3Address, blockTag: BlockTag) -> Web3Quantity:
    ## Returns the number of transactions ak.s. nonce sent from an address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
      nonce   = ledger.getNonce(address)
    result = w3Qty nonce

  server.rpc("eth_blockNumber") do() -> Web3Quantity:
    ## Returns integer of the current block number the client is on.
    result = w3Qty(api.chain.latestNumber)

  server.rpc("eth_chainId") do() -> Web3Quantity:
    return w3Qty(distinctBase(api.com.chainId))

  server.rpc("eth_getCode") do(data: Web3Address, blockTag: BlockTag) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## blockTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
    result = ledger.getCode(address).bytes()

  server.rpc("eth_getBlockByHash") do(data: Web3Hash, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let blockHash = data.ethHash

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
        startingBlock: w3Qty api.com.syncStart,
        currentBlock : w3Qty api.com.syncCurrent,
        highestBlock : w3Qty api.com.syncHighest
      )
      return SyncingStatus(syncing: true, syncObject: sync)
    else:
      return SyncingStatus(syncing: false)

  proc getLogsForBlock(
      chain: ForkedChainRef,
      blk: EthBlock,
      opts: FilterOptions): seq[FilterLog]
        {.gcsafe, raises: [RlpError].} =
    if headerBloomFilter(blk.header, opts.address, opts.topics):
      let receipts = chain.db.getReceipts(blk.header.receiptsRoot)
      # Note: this will hit assertion error if number of block transactions
      # do not match block receipts.
      # Although this is fine as number of receipts should always match number
      # of transactions
      let logs = deriveLogs(blk.header, blk.transactions, receipts)
      let filteredLogs = filterLogs(logs, opts.address, opts.topics)
      return filteredLogs
    else:
      return @[]

  proc getLogsForRange(
      chain: ForkedChainRef,
      start: common.BlockNumber,
      finish: common.BlockNumber,
      opts: FilterOptions): seq[FilterLog]
        {.gcsafe, raises: [RlpError].} =
    var
      logs = newSeq[FilterLog]()
      blockNum = start

    while blockNum <= finish:
      let
        blk = chain.blockByNumber(blockNum).valueOr:
                return logs
        filtered = chain.getLogsForBlock(blk, opts)
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
        hash = ethHash filterOptions.blockHash.expect("blockHash")
        blk = api.chain.blockByHash(hash).valueOr:
          raise newException(ValueError, "Block not found")
      return getLogsForBlock(api.chain, blk, filterOptions)
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
    result = res.output

# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/json,
  json_rpc/rpcserver,
  ./rpc_utils,
  ./rpc_types,
  ../tracer, ../vm_types,
  ../common/common,
  ../beacon/web3_eth_conv,
  ../core/tx_pool,
  web3/conversions

{.push raises: [].}

type
  TraceOptions = object
    disableStorage: Option[bool]
    disableMemory: Option[bool]
    disableStack: Option[bool]
    disableState: Option[bool]
    disableStateDiff: Option[bool]

TraceOptions.useDefaultSerializationIn JrpcConv

proc isTrue(x: Option[bool]): bool =
  result = x.isSome and x.get() == true

proc traceOptionsToFlags(options: Option[TraceOptions]): set[TracerFlags] =
  if options.isSome:
    let opts = options.get
    if opts.disableStorage.isTrue: result.incl TracerFlags.DisableStorage
    if opts.disableMemory.isTrue : result.incl TracerFlags.DisableMemory
    if opts.disableStack.isTrue  : result.incl TracerFlags.DisableStack
    if opts.disableState.isTrue  : result.incl TracerFlags.DisableState
    if opts.disableStateDiff.isTrue: result.incl TracerFlags.DisableStateDiff

proc setupDebugRpc*(com: CommonRef, txPool: TxPoolRef, rpcsrv: RpcServer) =
  let chainDB = com.db

  rpcsrv.rpc("debug_traceTransaction") do(data: Web3Hash, options: Option[TraceOptions]) -> JsonNode:
    ## The traceTransaction debugging method will attempt to run the transaction in the exact
    ## same manner as it was executed on the network. It will replay any transaction that may
    ## have been executed prior to this one before it will finally attempt to execute the
    ## transaction that corresponds to the given hash.
    ##
    ## In addition to the hash of the transaction you may give it a secondary optional argument,
    ## which specifies the options for this specific call. The possible options are:
    ##
    ## * disableStorage: BOOL. Setting this to true will disable storage capture (default = false).
    ## * disableMemory: BOOL. Setting this to true will disable memory capture (default = false).
    ## * disableStack: BOOL. Setting this to true will disable stack capture (default = false).
    ## * disableState: BOOL. Setting this to true will disable state trie capture (default = false).
    let
      txHash = ethHash(data)
      txDetails = chainDB.getTransactionKey(txHash)
      header = chainDB.getBlockHeader(txDetails.blockNumber)
      transactions = chainDB.getTransactions(header)
      flags = traceOptionsToFlags(options)

    traceTransaction(com, header, transactions, txDetails.index, flags)

  rpcsrv.rpc("debug_dumpBlockStateByNumber") do(quantityTag: BlockTag) -> JsonNode:
    ## Retrieves the state that corresponds to the block number and returns
    ## a list of accounts (including storage and code).
    ##
    ## quantityTag: integer of a block number, or the string "earliest",
    ## "latest" or "pending", as in the default block parameter.
    var
      header = chainDB.headerFromTag(quantityTag)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)

    dumpBlockState(com, EthBlock.init(move(header), move(body)))

  rpcsrv.rpc("debug_dumpBlockStateByHash") do(data: Web3Hash) -> JsonNode:
    ## Retrieves the state that corresponds to the block number and returns
    ## a list of accounts (including storage and code).
    ##
    ## data: Hash of a block.
    var
      h = data.ethHash
      blk = chainDB.getEthBlock(h)

    dumpBlockState(com, blk)

  rpcsrv.rpc("debug_traceBlockByNumber") do(quantityTag: BlockTag, options: Option[TraceOptions]) -> JsonNode:
    ## The traceBlock method will return a full stack trace of all invoked opcodes of all transaction
    ## that were included included in this block.
    ##
    ## quantityTag: integer of a block number, or the string "earliest",
    ## "latest" or "pending", as in the default block parameter.
    ## options: see debug_traceTransaction
    var
      header = chainDB.headerFromTag(quantityTag)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)
      flags = traceOptionsToFlags(options)

    traceBlock(com, EthBlock.init(move(header), move(body)), flags)

  rpcsrv.rpc("debug_traceBlockByHash") do(data: Web3Hash, options: Option[TraceOptions]) -> JsonNode:
    ## The traceBlock method will return a full stack trace of all invoked opcodes of all transaction
    ## that were included included in this block.
    ##
    ## data: Hash of a block.
    ## options: see debug_traceTransaction
    var
      h = data.ethHash
      header = chainDB.getBlockHeader(h)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)
      flags = traceOptionsToFlags(options)

    traceBlock(com, EthBlock.init(move(header), move(body)), flags)

  rpcsrv.rpc("debug_setHead") do(quantityTag: BlockTag) -> bool:
    ## Sets the current head of the local chain by block number.
    ## Note, this is a destructive action and may severely damage your chain.
    ## Use with extreme caution.
    let
      header = chainDB.headerFromTag(quantityTag)
    chainDB.setHead(header)

  rpcsrv.rpc("debug_getRawBlock") do(quantityTag: BlockTag) -> seq[byte]:
    ## Returns an RLP-encoded block.
    var
      header = chainDB.headerFromTag(quantityTag)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)

    rlp.encode(EthBlock.init(move(header), move(body)))

  rpcsrv.rpc("debug_getRawHeader") do(quantityTag: BlockTag) -> seq[byte]:
    ## Returns an RLP-encoded header.
    let header = chainDB.headerFromTag(quantityTag)
    rlp.encode(header)

  rpcsrv.rpc("debug_getRawReceipts") do(quantityTag: BlockTag) -> seq[seq[byte]]:
    ## Returns an array of EIP-2718 binary-encoded receipts.
    let header = chainDB.headerFromTag(quantityTag)
    for receipt in chainDB.getReceipts(header.receiptRoot):
      result.add rlp.encode(receipt)

  rpcsrv.rpc("debug_getRawTransaction") do(data: Web3Hash) -> seq[byte]:
    ## Returns an EIP-2718 binary-encoded transaction.
    let txHash = ethHash data
    let res = txPool.getItem(txHash)
    if res.isOk:
      return rlp.encode(res.get().tx)

    let txDetails = chainDB.getTransactionKey(txHash)
    if txDetails.index < 0:
      raise newException(ValueError, "Transaction not found " & data.toHex)

    let header = chainDB.getBlockHeader(txDetails.blockNumber)
    var tx: Transaction
    if chainDB.getTransaction(header.txRoot, txDetails.index, tx):
      return rlp.encode(tx)

    raise newException(ValueError, "Transaction not found " & data.toHex)

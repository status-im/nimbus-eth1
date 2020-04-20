# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  strutils, json, options,
  json_rpc/rpcserver, rpc_utils, eth/common,
  hexstrings, ../tracer, ../vm_types,
  ../db/[db_chain]

type
  TraceOptions = object
    disableStorage: Option[bool]
    disableMemory: Option[bool]
    disableStack: Option[bool]
    disableState: Option[bool]
    disableStateDiff: Option[bool]

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

proc setupDebugRpc*(chainDB: BaseChainDB, rpcsrv: RpcServer) =

  rpcsrv.rpc("debug_traceTransaction") do(data: EthHashStr, options: Option[TraceOptions]) -> JsonNode:
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
      txHash = toHash(data)
      txDetails = chainDB.getTransactionKey(txHash)
      blockHeader = chainDB.getBlockHeader(txDetails.blockNumber)
      blockHash = chainDB.getBlockHash(txDetails.blockNumber)
      blockBody = chainDB.getBlockBody(blockHash)
      flags = traceOptionsToFlags(options)

    result = traceTransaction(chainDB, blockHeader, blockBody, txDetails.index, flags)

  rpcsrv.rpc("debug_dumpBlockStateByNumber") do(quantityTag: string) -> JsonNode:
    ## Retrieves the state that corresponds to the block number and returns
    ## a list of accounts (including storage and code).
    ##
    ## quantityTag: integer of a block number, or the string "earliest",
    ## "latest" or "pending", as in the default block parameter.
    let
      header = chainDB.headerFromTag(quantityTag)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)

    result = dumpBlockState(chainDB, header, body)

  rpcsrv.rpc("debug_dumpBlockStateByHash") do(data: EthHashStr) -> JsonNode:
    ## Retrieves the state that corresponds to the block number and returns
    ## a list of accounts (including storage and code).
    ##
    ## data: Hash of a block.
    let
      h = data.toHash
      header = chainDB.getBlockHeader(h)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)

    result = dumpBlockState(chainDB, header, body)

  rpcsrv.rpc("debug_traceBlockByNumber") do(quantityTag: string, options: Option[TraceOptions]) -> JsonNode:
    ## The traceBlock method will return a full stack trace of all invoked opcodes of all transaction
    ## that were included included in this block.
    ##
    ## quantityTag: integer of a block number, or the string "earliest",
    ## "latest" or "pending", as in the default block parameter.
    ## options: see debug_traceTransaction
    let
      header = chainDB.headerFromTag(quantityTag)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)
      flags = traceOptionsToFlags(options)

    result = traceBlock(chainDB, header, body, flags)

  rpcsrv.rpc("debug_traceBlockByHash") do(data: EthHashStr, options: Option[TraceOptions]) -> JsonNode:
    ## The traceBlock method will return a full stack trace of all invoked opcodes of all transaction
    ## that were included included in this block.
    ##
    ## data: Hash of a block.
    ## options: see debug_traceTransaction
    let
      h = data.toHash
      header = chainDB.getBlockHeader(h)
      blockHash = chainDB.getBlockHash(header.blockNumber)
      body = chainDB.getBlockBody(blockHash)
      flags = traceOptionsToFlags(options)

    result = traceBlock(chainDB, header, body, flags)

  rpcsrv.rpc("debug_setHead") do(quantityTag: string):
    ## Sets the current head of the local chain by block number.
    ## Note, this is a destructive action and may severely damage your chain.
    ## Use with extreme caution.
    let
      header = chainDB.headerFromTag(quantityTag)
    chainDB.setHead(header)

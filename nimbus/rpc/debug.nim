# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  strutils, hexstrings, eth_p2p, options,
  ../db/[db_chain, state_db, storage_types],
  json_rpc/rpcserver, json, macros, rpc_utils,
  eth_common

type
  TraceTxOptions = object
    disableStorage: Option[bool]
    disableMemory: Option[bool]
    disableStack: Option[bool]

proc setupDebugRpc*(chain: BaseChainDB, rpcsrv: RpcServer) =

  proc getBlockBody(hash: Hash256): BlockBody =
    if not chain.getBlockBody(hash, result):
      raise newException(ValueError, "Error when retrieving block body")

  rpcsrv.rpc("debug_traceTransaction") do(data: HexDataStr, options: Option[TraceTxOptions]) -> JsonNode:
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
    let
      txHash = strToHash(data.string)
      txDetails = chain.getTransactionKey(txHash)
      blockHeader = chain.getBlockHeader(txDetails.blockNumber)
      blockHash = chain.getBlockHash(txDetails.blockNumber)
      blockBody = getBlockBody(blockHash)

# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[times, sequtils],
  json_rpc/[rpcproxy, rpcserver], nimcrypto/[hash, keccak],
  web3/conversions, # sigh, for FixedBytes marshalling
  eth/[common/eth_types, rlp],
  # TODO: Using the Nimbus json-rpc helpers, but they could use some rework as
  # they bring a whole lot of other stuff with them.
  ../../nimbus/rpc/[rpc_types, hexstrings, rpc_utils],
  ../../nimbus/errors, # for ValidationError, should be exported instead
  ../network/history/[history_network, history_content]

# Subset of Eth JSON-RPC API: https://eth.wiki/json-rpc/API
# Supported subset will eventually be found here:
# https://github.com/ethereum/stateless-ethereum-specs/blob/master/portal-network.md#json-rpc-api
#
# In order to already support these calls before every part of the Portal
# Network is up, one plan is to get the data directly from an external client
# through RPC calls. Practically just playing a proxy to that client.
# Can be done by just forwarding the rpc call, or by adding a call here, but
# that would introduce a unnecessary serializing/deserializing step.

# Note: Similar as `populateBlockObject` from rpc_utils, but more limited as
# there is currently only access to the block header.
proc buildBlockObject*(
    header: BlockHeader, body: BlockBody,
    fullTx = true, isUncle = false):
    BlockObject {.raises: [Defect, ValidationError].} =
  let blockHash = header.blockHash

  result.number = some(encodeQuantity(header.blockNumber))
  result.hash = some(blockHash)
  result.parentHash = header.parentHash
  result.nonce = some(hexDataStr(header.nonce))
  result.sha3Uncles = header.ommersHash
  result.logsBloom = FixedBytes[256] header.bloom
  result.transactionsRoot = header.txRoot
  result.stateRoot = header.stateRoot
  result.receiptsRoot = header.receiptRoot
  result.miner = header.coinbase
  result.difficulty = encodeQuantity(header.difficulty)
  result.extraData = hexDataStr(header.extraData)

  # TODO: This is optional according to
  # https://playground.open-rpc.org/?schemaUrl=https://raw.githubusercontent.com/ethereum/eth1.0-apis/assembled-spec/openrpc.json
  # So we should probably change `BlockObject`.
  result.totalDifficulty = encodeQuantity(UInt256.low())

  let size = sizeof(BlockHeader) - sizeof(Blob) + header.extraData.len
  result.size = encodeQuantity(size.uint)

  result.gasLimit  = encodeQuantity(header.gasLimit.uint64)
  result.gasUsed   = encodeQuantity(header.gasUsed.uint64)
  result.timestamp = encodeQuantity(header.timeStamp.toUnix.uint64)

  if not isUncle:
    result.uncles = body.uncles.map(proc(h: BlockHeader): Hash256 = h.blockHash)

    if fullTx:
      var i = 0
      for tx in body.transactions:
        # ValidationError from tx.getSender in populateTransactionObject
        result.transactions.add %(populateTransactionObject(tx, header, i))
        inc i
    else:
      for tx in body.transactions:
        result.transactions.add %(keccak256.digest(rlp.encode(tx)))

proc installEthApiHandlers*(
    # Currently only HistoryNetwork needed, later we might want a master object
    # holding all the networks.
    rpcServerWithProxy: var RpcProxy, historyNetwork: HistoryNetwork)
    {.raises: [Defect, CatchableError].} =

  # Supported API
  rpcServerWithProxy.registerProxyMethod("eth_blockNumber")

  rpcServerWithProxy.registerProxyMethod("eth_call")

  rpcServerWithProxy.registerProxyMethod("eth_chainId")

  rpcServerWithProxy.registerProxyMethod("eth_estimateGas")

  rpcServerWithProxy.registerProxyMethod("eth_feeHistory")

  rpcServerWithProxy.registerProxyMethod("eth_getBalance")

  # rpcServerWithProxy.registerProxyMethod("eth_getBlockByHash")

  rpcServerWithProxy.registerProxyMethod("eth_getBlockByNumber")

  # rpcServerWithProxy.registerProxyMethod("eth_getBlockTransactionCountByHash")

  rpcServerWithProxy.registerProxyMethod("eth_getBlockTransactionCountByNumber")

  rpcServerWithProxy.registerProxyMethod("eth_getCode")

  rpcServerWithProxy.registerProxyMethod("eth_getRawTransactionByHash")

  rpcServerWithProxy.registerProxyMethod("eth_getRawTransactionByBlockHashAndIndex")

  rpcServerWithProxy.registerProxyMethod("eth_getRawTransactionByBlockNumberAndIndex")

  rpcServerWithProxy.registerProxyMethod("eth_getStorageAt")

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionByBlockHashAndIndex")

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionByBlockNumberAndIndex")

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionByHash")

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionCount")

  rpcServerWithProxy.registerProxyMethod("eth_getTransactionReceipt")

  rpcServerWithProxy.registerProxyMethod("eth_getUncleByBlockHashAndIndex")

  rpcServerWithProxy.registerProxyMethod("eth_getUncleByBlockNumberAndIndex")

  rpcServerWithProxy.registerProxyMethod("eth_getUncleCountByBlockHash")

  rpcServerWithProxy.registerProxyMethod("eth_getUncleCountByBlockNumber")

  rpcServerWithProxy.registerProxyMethod("eth_getProof")

  rpcServerWithProxy.registerProxyMethod("eth_sendRawTransaction")

  # Optional API

  rpcServerWithProxy.registerProxyMethod("eth_gasPrice")

  rpcServerWithProxy.registerProxyMethod("eth_getFilterChanges")

  rpcServerWithProxy.registerProxyMethod("eth_getFilterLogs")

  rpcServerWithProxy.registerProxyMethod("eth_getLogs")

  rpcServerWithProxy.registerProxyMethod("eth_newBlockFilter")

  rpcServerWithProxy.registerProxyMethod("eth_newFilter")

  rpcServerWithProxy.registerProxyMethod("eth_newPendingTransactionFilter")

  rpcServerWithProxy.registerProxyMethod("eth_pendingTransactions")

  rpcServerWithProxy.registerProxyMethod("eth_syncing")

  rpcServerWithProxy.registerProxyMethod("eth_uninstallFilter")

  # Supported API through the Portal Network

  rpcServerWithProxy.rpc("eth_getBlockByHash") do(
      data: EthHashStr, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if
    ## false only the hashes of the transactions.
    ## Note: transactions and uncles are currently not implemented.
    ##
    ## Returns BlockObject or nil when no block was found.
    let
      blockHash = data.toHash()
      contentKeyType = ContentKeyType(chainId: 1'u16, blockHash: blockHash)

      contentKeyHeader =
        ContentKey(contentType: blockHeader, blockHeaderKey: contentKeyType)
      contentKeyBody =
        ContentKey(contentType: blockBody, blockBodyKey: contentKeyType)

    let headerContent = await historyNetwork.getContent(contentKeyHeader)
    if headerContent.isNone():
      return none(BlockObject)

    var rlp = rlpFromBytes(headerContent.get())
    let blockHeader = rlp.read(BlockHeader)

    let bodyContent = await historyNetwork.getContent(contentKeyBody)

    if bodyContent.isSome():
      var rlp = rlpFromBytes(bodyContent.get())
      let blockBody = rlp.read(BlockBody)

      return some(buildBlockObject(blockHeader, blockBody))
    else:
      return none(BlockObject)

  rpcServerWithProxy.rpc("eth_getBlockTransactionCountByHash") do(
      data: EthHashStr) -> HexQuantityStr:
    ## Returns the number of transactions in a block from a block matching the
    ## given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    let
      blockHash = data.toHash()
      contentKeyType = ContentKeyType(chainId: 1'u16, blockHash: blockHash)
      contentKeyBody =
        ContentKey(contentType: blockBody, blockBodyKey: contentKeyType)

    let bodyContent = await historyNetwork.getContent(contentKeyBody)

    if bodyContent.isSome():
      var rlp = rlpFromBytes(bodyContent.get())
      let blockBody = rlp.read(BlockBody)

      var txCount:uint = 0
      for tx in blockBody.transactions:
        txCount.inc()

      return encodeQuantity(txCount)
    else:
      raise newException(ValueError, "Could not find block with requested hash")

  # Note: can't implement this yet as the fluffy node doesn't know the relation
  # of tx hash -> block number -> block hash, in order to get the receipt
  # from from the block with that block hash. The Canonical Indices Network
  # would need to be implemented to get this information.
  # rpcServerWithProxy.rpc("eth_getTransactionReceipt") do(
  #     data: EthHashStr) -> Option[ReceiptObject]:

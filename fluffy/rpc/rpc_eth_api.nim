# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[times, sequtils, typetraits],
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  web3/conversions, # sigh, for FixedBytes marshalling
  eth/[common/eth_types, rlp],
  ../../nimbus/rpc/[rpc_types, hexstrings, filters],
  ../../nimbus/transaction,
  # TODO: this is a bit weird but having this import makes beacon_light_client
  # to fail compilation due throwing undeclared `CatchableError` in
  # `vendor/nimbus-eth2/beacon_chain/spec/keystore.nim`. This is most probably
  # caused by `readValue` clashing ?
  # ../../nimbus/common/chain_config
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

# Some similar code as from nimbus `rpc_utils`, but avoiding that import as it
# brings in  a lot more. Should restructure `rpc_utils` a bit before using that.
func toHash*(value: array[32, byte]): Hash256 =
  result.data = value

func toHash*(value: EthHashStr): Hash256 {.raises: [Defect, ValueError].} =
  hexToPaddedByteArray[32](value.string).toHash

func init*(
    T: type TransactionObject,
    tx: Transaction, header: BlockHeader, txIndex: int):
    T {.raises: [Defect, ValidationError].} =
  TransactionObject(
    blockHash: some(header.blockHash),
    blockNumber: some(encodeQuantity(header.blockNumber)),
    `from`: tx.getSender(),
    gas: encodeQuantity(tx.gasLimit.uint64),
    gasPrice: encodeQuantity(tx.gasPrice.uint64),
    hash: tx.rlpHash,
    input: tx.payload,
    nonce: encodeQuantity(tx.nonce.uint64),
    to: some(tx.destination),
    transactionIndex: some(encodeQuantity(txIndex.uint64)),
    value: encodeQuantity(tx.value),
    v: encodeQuantity(tx.V.uint),
    r: encodeQuantity(tx.R),
    s: encodeQuantity(tx.S)
  )

# Note: Similar as `populateBlockObject` from rpc_utils, but lacking the
# total difficulty
func init*(
    T: type BlockObject,
    header: BlockHeader, body: BlockBody,
    fullTx = true, isUncle = false):
    T {.raises: [Defect, ValidationError].} =
  let blockHash = header.blockHash

  var blockObject = BlockObject(
    number: some(encodeQuantity(header.blockNumber)),
    hash: some(blockHash),
    parentHash: header.parentHash,
    nonce: some(hexDataStr(header.nonce)),
    sha3Uncles: header.ommersHash,
    logsBloom: FixedBytes[256] header.bloom,
    transactionsRoot: header.txRoot,
    stateRoot: header.stateRoot,
    receiptsRoot: header.receiptRoot,
    miner: header.coinbase,
    difficulty: encodeQuantity(header.difficulty),
    extraData: hexDataStr(header.extraData),
    # TODO: This is optional according to
    # https://playground.open-rpc.org/?schemaUrl=https://raw.githubusercontent.com/ethereum/eth1.0-apis/assembled-spec/openrpc.json
    # So we should probably change `BlockObject`.
    totalDifficulty: encodeQuantity(UInt256.low()),
    gasLimit: encodeQuantity(header.gasLimit.uint64),
    gasUsed: encodeQuantity(header.gasUsed.uint64),
    timestamp: encodeQuantity(header.timestamp.toUnix.uint64)
  )

  let size = sizeof(BlockHeader) - sizeof(Blob) + header.extraData.len
  blockObject.size = encodeQuantity(size.uint)

  if not isUncle:
    blockObject.uncles =
      body.uncles.map(proc(h: BlockHeader): Hash256 = h.blockHash)

    if fullTx:
      var i = 0
      for tx in body.transactions:
        # ValidationError from tx.getSender in TransactionObject.init
        blockObject.transactions.add %(TransactionObject.init(tx, header, i))
        inc i
    else:
      for tx in body.transactions:
        blockObject.transactions.add %(keccakHash(rlp.encode(tx)))

  blockObject

proc installEthApiHandlers*(
    # Currently only HistoryNetwork needed, later we might want a master object
    # holding all the networks.
    rpcServerWithProxy: var RpcProxy, historyNetwork: HistoryNetwork)
    {.raises: [Defect, CatchableError].} =

  # Supported API
  rpcServerWithProxy.registerProxyMethod("eth_blockNumber")

  rpcServerWithProxy.registerProxyMethod("eth_call")

  # rpcServerWithProxy.registerProxyMethod("eth_chainId")

  rpcServerWithProxy.registerProxyMethod("eth_estimateGas")

  rpcServerWithProxy.registerProxyMethod("eth_feeHistory")

  rpcServerWithProxy.registerProxyMethod("eth_getBalance")

  # rpcServerWithProxy.registerProxyMethod("eth_getBlockByHash")

  # rpcServerWithProxy.registerProxyMethod("eth_getBlockByNumber")

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

  # rpcServerWithProxy.registerProxyMethod("eth_getLogs")

  rpcServerWithProxy.registerProxyMethod("eth_newBlockFilter")

  rpcServerWithProxy.registerProxyMethod("eth_newFilter")

  rpcServerWithProxy.registerProxyMethod("eth_newPendingTransactionFilter")

  rpcServerWithProxy.registerProxyMethod("eth_pendingTransactions")

  rpcServerWithProxy.registerProxyMethod("eth_syncing")

  rpcServerWithProxy.registerProxyMethod("eth_uninstallFilter")

  # Supported API through the Portal Network

  rpcServerWithProxy.rpc("eth_chainId") do() -> HexQuantityStr:
    # The Portal Network can only support MainNet at the moment, so always return
    # 1
    return encodeQuantity(uint64(1))

  rpcServerWithProxy.rpc("eth_getBlockByHash") do(
      data: EthHashStr, fullTransactions: bool) -> Option[BlockObject]:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if
    ## false only the hashes of the transactions.
    ##
    ## Returns BlockObject or nil when no block was found.
    let
      blockHash = data.toHash()
      (header, body) = (await historyNetwork.getBlock(blockHash)).valueOr:
        return none(BlockObject)

    return some(BlockObject.init(header, body))

  # TODO: add test to local testnet, it requires activating accumulator
  # in testnet script
  rpcServerWithProxy.rpc("eth_getBlockByNumber") do(
      quantityTag: string, fullTransactions: bool) -> Option[BlockObject]:
    # TODO: for now support only numeric queries, as it is not obvious how to
    # retrieve pending or even latest block.
    if not isValidHexQuantity(quantityTag):
      raise newException(ValueError, "Provided tag should be valid hex number")

    let
      blockNumber = fromHex(UInt256, quantityTag)
      maybeBlock = (await historyNetwork.getBlock(blockNumber)).valueOr:
        raise newException(ValueError, error)

    if maybeBlock.isNone():
      return none(BlockObject)
    else:
      let (header, body) = maybeBlock.get()
      return some(BlockObject.init(header, body))

  rpcServerWithProxy.rpc("eth_getBlockTransactionCountByHash") do(
      data: EthHashStr) -> HexQuantityStr:
    ## Returns the number of transactions in a block from a block matching the
    ## given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    let
      blockHash = data.toHash()
      (_, body) = (await historyNetwork.getBlock(blockHash)).valueOr:
        raise newException(ValueError, "Could not find block with requested hash")

    var txCount: uint = 0
    for tx in body.transactions:
      txCount.inc()

    return encodeQuantity(txCount)

  # Note: can't implement this yet as the fluffy node doesn't know the relation
  # of tx hash -> block number -> block hash, in order to get the receipt
  # from from the block with that block hash. The Canonical Indices Network
  # would need to be implemented to get this information.
  # rpcServerWithProxy.rpc("eth_getTransactionReceipt") do(
  #     data: EthHashStr) -> Option[ReceiptObject]:

  rpcServerWithProxy.rpc("eth_getLogs") do(
      filterOptions: FilterOptions) -> seq[FilterLog]:
    if filterOptions.blockHash.isNone():
      # Currently only queries by blockhash are supported.
      # To support range queries the Indicies network is required.
      raise newException(ValueError,
        "Unsupported query: Only `blockHash` queries are currently supported")

    let hash = filterOptions.blockHash.unsafeGet()

    let header = (await historyNetwork.getVerifiedBlockHeader(hash)).valueOr:
      raise newException(ValueError,
        "Could not find header with requested hash")

    if headerBloomFilter(header, filterOptions.address, filterOptions.topics):
      # TODO: These queries could be done concurrently, investigate if there
      # are no assumptions about usage of concurrent queries on portal
      # wire protocol level
      let
        body = (await historyNetwork.getBlockBody(hash, header)).valueOr:
          raise newException(ValueError,
            "Could not find block body for requested hash")
        receipts = (await historyNetwork.getReceipts(hash, header)).valueOr:
          raise newException(ValueError,
            "Could not find receipts for requested hash")

        logs = deriveLogs(header, body.transactions, receipts)
        filteredLogs = filterLogs(
          logs, filterOptions.address, filterOptions.topics)

      return filteredLogs
    else:
      # bloomfilter returned false, there are no logs matching the criteria
      return @[]

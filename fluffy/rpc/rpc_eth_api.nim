# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[times, sequtils, strutils, typetraits],
  json_rpc/[rpcproxy, rpcserver],
  web3/[conversions], # sigh, for FixedBytes marshalling
  eth/[common/eth_types, rlp],
  beacon_chain/spec/forks,
  ../../nimbus/rpc/[rpc_types, filters],
  ../../nimbus/transaction,
  # TODO: this is a bit weird but having this import makes beacon_light_client
  # to fail compilation due throwing undeclared `CatchableError` in
  # `vendor/nimbus-eth2/beacon_chain/spec/keystore.nim`. This is most probably
  # caused by `readValue` clashing ?
  # ../../nimbus/common/chain_config
  ../network/history/[history_network, history_content],
  ../network/beacon/beacon_light_client

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
func toHash*(value: rpc_types.Hash256): eth_types.Hash256 =
  result.data = value.bytes

func init*(
    T: type TransactionObject,
    tx: eth_types.Transaction, header: eth_types.BlockHeader, txIndex: int):
    T {.raises: [ValidationError].} =
  TransactionObject(
    blockHash: some(w3Hash header.blockHash),
    blockNumber: some(Quantity(header.blockNumber.truncate(uint64))),
    `from`: w3Addr tx.getSender(),
    gas: Quantity(tx.gasLimit),
    gasPrice: Quantity(tx.gasPrice),
    hash: w3Hash tx.rlpHash,
    input: tx.payload,
    nonce: Quantity(tx.nonce),
    to: some(w3Addr tx.destination),
    transactionIndex: some(Quantity(txIndex)),
    value: tx.value,
    v: Quantity(tx.V),
    r: tx.R,
    s: tx.S,
    `type`: some(Quantity(tx.txType)),
    maxFeePerGas: some(Quantity(tx.maxFee)),
    maxPriorityFeePerGas: some(Quantity(tx.maxPriorityFee)),
  )

# Note: Similar as `populateBlockObject` from rpc_utils, but lacking the
# total difficulty
func init*(
    T: type BlockObject,
    header: eth_types.BlockHeader, body: BlockBody,
    fullTx = true, isUncle = false):
    T {.raises: [ValidationError].} =
  let blockHash = header.blockHash

  var blockObject = BlockObject(
    number: Quantity(header.blockNumber.truncate(uint64)),
    hash: w3Hash blockHash,
    parentHash: w3Hash header.parentHash,
    nonce: some(FixedBytes[8](header.nonce)),
    sha3Uncles: w3Hash header.ommersHash,
    logsBloom: FixedBytes[256] header.bloom,
    transactionsRoot: w3Hash header.txRoot,
    stateRoot: w3Hash header.stateRoot,
    receiptsRoot: w3Hash header.receiptRoot,
    miner: w3Addr header.coinbase,
    difficulty: header.difficulty,
    extraData: HistoricExtraData header.extraData,
    # TODO: This is optional according to
    # https://playground.open-rpc.org/?schemaUrl=https://raw.githubusercontent.com/ethereum/eth1.0-apis/assembled-spec/openrpc.json
    # So we should probably change `BlockObject`.
    totalDifficulty: UInt256.low(),
    gasLimit: Quantity(header.gasLimit.uint64),
    gasUsed: Quantity(header.gasUsed.uint64),
    timestamp: Quantity(header.timestamp.uint64)
  )

  let size = sizeof(BlockHeader) - sizeof(Blob) + header.extraData.len
  blockObject.size = Quantity(size.uint)

  if not isUncle:
    blockObject.uncles =
      body.uncles.map(proc(h: BlockHeader): rpc_types.Hash256 = w3Hash h.blockHash)

    if fullTx:
      var i = 0
      for tx in body.transactions:
        # ValidationError from tx.getSender in TransactionObject.init
        blockObject.transactions.add txOrHash(TransactionObject.init(tx, header, i))
        inc i
    else:
      for tx in body.transactions:
        blockObject.transactions.add txOrHash(w3Hash keccakHash(rlp.encode(tx)))

  blockObject

proc installEthApiHandlers*(
    # Currently only HistoryNetwork needed, later we might want a master object
    # holding all the networks.
    rpcServerWithProxy: var RpcProxy, historyNetwork: HistoryNetwork,
    beaconLightClient: Opt[LightClient])
    {.raises: [CatchableError].} =

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

  rpcServerWithProxy.rpc("eth_chainId") do() -> Quantity:
    # The Portal Network can only support MainNet at the moment, so always return
    # 1
    return Quantity(uint64(1))

  rpcServerWithProxy.rpc("eth_getBlockByHash") do(
      data: rpc_types.Hash256, fullTransactions: bool) -> Option[BlockObject]:
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

    return some(BlockObject.init(header, body, fullTransactions))

  rpcServerWithProxy.rpc("eth_getBlockByNumber") do(
      quantityTag: BlockTag, fullTransactions: bool) -> Option[BlockObject]:

    if quantityTag.kind == bidAlias:
      let tag = quantityTag.alias.toLowerAscii
      case tag
      of "latest":
        # TODO:
        # I assume this would refer to the content in the latest optimistic update
        # in case the majority treshold is not met. And if it is met it is the
        # same as the safe version?
        raise newException(ValueError, "Latest tag not yet implemented")
      of "earliest":
        raise newException(ValueError, "Earliest tag not yet implemented")
      of "safe":
        if beaconLightClient.isNone():
          raise newException(ValueError, "Safe tag not yet implemented")

        withForkyStore(beaconLightClient.value().store[]):
          when lcDataFork > LightClientDataFork.Altair:
            let
              blockHash = forkyStore.optimistic_header.execution.block_hash
              (header, body) = (await historyNetwork.getBlock(blockHash)).valueOr:
                return none(BlockObject)

            return some(BlockObject.init(header, body, fullTransactions))
          else:
            raise newException(
              ValueError, "Not available before Capella - not synced?")
      of "finalized":
        if beaconLightClient.isNone():
          raise newException(ValueError, "Finalized tag not yet implemented")

        withForkyStore(beaconLightClient.value().store[]):
          when lcDataFork > LightClientDataFork.Altair:
            let
              blockHash = forkyStore.finalized_header.execution.block_hash
              (header, body) = (await historyNetwork.getBlock(blockHash)).valueOr:
                return none(BlockObject)

            return some(BlockObject.init(header, body, fullTransactions))
          else:
            raise newException(
              ValueError, "Not available before Capella - not synced?")
      of "pending":
        raise newException(ValueError, "Pending tag not yet implemented")
      else:
        raise newException(ValueError, "Unsupported block tag " & tag)
    else:
      let
        blockNumber = quantityTag.number.toBlockNumber
        maybeBlock = (await historyNetwork.getBlock(blockNumber)).valueOr:
          raise newException(ValueError, error)

      if maybeBlock.isNone():
        return none(BlockObject)
      else:
        let (header, body) = maybeBlock.get()
        return some(BlockObject.init(header, body, fullTransactions))

  rpcServerWithProxy.rpc("eth_getBlockTransactionCountByHash") do(
      data: rpc_types.Hash256) -> Quantity:
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

    return Quantity(txCount)

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

    let hash = ethHash filterOptions.blockHash.unsafeGet()

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

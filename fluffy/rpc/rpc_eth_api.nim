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
  chronicles,
  web3/conversions, # sigh, for FixedBytes marshalling
  web3/eth_api_types,
  web3/primitives as web3types,
  eth/common/eth_types,
  beacon_chain/spec/forks,
  ../common/common_utils,
  ../network/history/[history_network, history_content],
  ../network/state/[state_network, state_content, state_endpoints],
  ../network/beacon/beacon_light_client

from ../../nimbus/transaction import getSender, ValidationError
from ../../nimbus/rpc/filters import headerBloomFilter, deriveLogs, filterLogs
from ../../nimbus/beacon/web3_eth_conv import w3Addr, w3Hash, ethHash

# Subset of Ethereum execution JSON-RPC API:
# https://ethereum.github.io/execution-apis/api-documentation/
#
# Currently supported subset:
# - eth_chainId
# - eth_getBlockByHash
# - eth_getBlockByNumber
# - eth_getBlockTransactionCountByHash
# - eth_getLogs - Partially: only requests by block hash
#
# In order to be able to use Fluffy as drop-in replacement for apps/tools that
# use the JSON RPC API, unsupported methods can be forwarded to a configured
# web3 provider.
# Supported methods will be handled by Fluffy by making use of the Portal network,
# unsupported methods will be proxied to the given web3 provider.
#

# Some similar code as from nimbus `rpc_utils`, but avoiding that import as it
# brings in  a lot more. Should restructure `rpc_utils` a bit before using that.
func toHash*(value: eth_api_types.Hash256): eth_types.Hash256 =
  result.data = value.bytes

func init*(
    T: type TransactionObject,
    tx: eth_types.Transaction,
    header: eth_types.BlockHeader,
    txIndex: int,
): T {.raises: [ValidationError].} =
  TransactionObject(
    blockHash: Opt.some(w3Hash header.blockHash),
    blockNumber: Opt.some(eth_api_types.BlockNumber(header.number)),
    `from`: w3Addr tx.getSender(),
    gas: Quantity(tx.gasLimit),
    gasPrice: Quantity(tx.gasPrice),
    hash: w3Hash tx.rlpHash,
    input: tx.payload,
    nonce: Quantity(tx.nonce),
    to: Opt.some(w3Addr tx.destination),
    transactionIndex: Opt.some(Quantity(txIndex)),
    value: tx.value,
    v: Quantity(tx.V),
    r: tx.R,
    s: tx.S,
    `type`: Opt.some(Quantity(tx.txType)),
    maxFeePerGas: Opt.some(Quantity(tx.maxFeePerGas)),
    maxPriorityFeePerGas: Opt.some(Quantity(tx.maxPriorityFeePerGas)),
  )

# Note: Similar as `populateBlockObject` from rpc_utils, but lacking the
# total difficulty
func init*(
    T: type BlockObject,
    header: eth_types.BlockHeader,
    body: BlockBody,
    fullTx = true,
    isUncle = false,
): T {.raises: [ValidationError].} =
  let blockHash = header.blockHash

  var blockObject = BlockObject(
    number: eth_api_types.BlockNumber(header.number),
    hash: w3Hash blockHash,
    parentHash: w3Hash header.parentHash,
    nonce: Opt.some(FixedBytes[8](header.nonce)),
    sha3Uncles: w3Hash header.ommersHash,
    logsBloom: FixedBytes[256] header.logsBloom,
    transactionsRoot: w3Hash header.txRoot,
    stateRoot: w3Hash header.stateRoot,
    receiptsRoot: w3Hash header.receiptsRoot,
    miner: w3Addr header.coinbase,
    difficulty: header.difficulty,
    extraData: HistoricExtraData header.extraData,
    # TODO: This is optional according to
    # https://playground.open-rpc.org/?schemaUrl=https://raw.githubusercontent.com/ethereum/eth1.0-apis/assembled-spec/openrpc.json
    # So we should probably change `BlockObject`.
    totalDifficulty: UInt256.low(),
    gasLimit: Quantity(header.gasLimit),
    gasUsed: Quantity(header.gasUsed),
    timestamp: Quantity(header.timestamp),
  )

  let size = sizeof(BlockHeader) - sizeof(Blob) + header.extraData.len
  blockObject.size = Quantity(size.uint)

  if not isUncle:
    blockObject.uncles = body.uncles.map(
      proc(h: eth_types.BlockHeader): eth_api_types.Hash256 =
        w3Hash h.blockHash
    )

    if fullTx:
      var i = 0
      for tx in body.transactions:
        # ValidationError from tx.getSender in TransactionObject.init
        blockObject.transactions.add txOrHash(TransactionObject.init(tx, header, i))
        inc i
    else:
      for tx in body.transactions:
        blockObject.transactions.add txOrHash(w3Hash rlpHash(tx))

  blockObject

proc installEthApiHandlers*(
    rpcServerWithProxy: var RpcProxy,
    historyNetwork: HistoryNetwork,
    beaconLightClient: Opt[LightClient],
    stateNetwork: Opt[StateNetwork],
) =
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
    data: eth_api_types.Hash256, fullTransactions: bool
  ) -> Opt[BlockObject]:
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
        return Opt.none(BlockObject)

    return Opt.some(BlockObject.init(header, body, fullTransactions))

  rpcServerWithProxy.rpc("eth_getBlockByNumber") do(
    quantityTag: RtBlockIdentifier, fullTransactions: bool
  ) -> Opt[BlockObject]:
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
                return Opt.none(BlockObject)

            return Opt.some(BlockObject.init(header, body, fullTransactions))
          else:
            raise newException(ValueError, "Not available before Capella - not synced?")
      of "finalized":
        if beaconLightClient.isNone():
          raise newException(ValueError, "Finalized tag not yet implemented")

        withForkyStore(beaconLightClient.value().store[]):
          when lcDataFork > LightClientDataFork.Altair:
            let
              blockHash = forkyStore.finalized_header.execution.block_hash
              (header, body) = (await historyNetwork.getBlock(blockHash)).valueOr:
                return Opt.none(BlockObject)

            return Opt.some(BlockObject.init(header, body, fullTransactions))
          else:
            raise newException(ValueError, "Not available before Capella - not synced?")
      of "pending":
        raise newException(ValueError, "Pending tag not yet implemented")
      else:
        raise newException(ValueError, "Unsupported block tag " & tag)
    else:
      let
        blockNumber = quantityTag.number.uint64
        (header, body) = (await historyNetwork.getBlock(blockNumber)).valueOr:
          return Opt.none(BlockObject)

      return Opt.some(BlockObject.init(header, body, fullTransactions))

  rpcServerWithProxy.rpc("eth_getBlockTransactionCountByHash") do(
    data: eth_api_types.Hash256
  ) -> Quantity:
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
  #     data: EthHashStr) -> Opt[ReceiptObject]:

  rpcServerWithProxy.rpc("eth_getLogs") do(
    filterOptions: FilterOptions
  ) -> seq[LogObject]:
    if filterOptions.blockHash.isNone():
      # Currently only queries by blockhash are supported.
      # TODO: Can impolement range queries by block number now.
      raise newException(
        ValueError,
        "Unsupported query: Only `blockHash` queries are currently supported",
      )

    let hash = ethHash filterOptions.blockHash.unsafeGet()

    let header = (await historyNetwork.getVerifiedBlockHeader(hash)).valueOr:
      raise newException(ValueError, "Could not find header with requested hash")

    if headerBloomFilter(header, filterOptions.address, filterOptions.topics):
      # TODO: These queries could be done concurrently, investigate if there
      # are no assumptions about usage of concurrent queries on portal
      # wire protocol level
      let
        body = (await historyNetwork.getBlockBody(hash, header)).valueOr:
          raise newException(ValueError, "Could not find block body for requested hash")
        receipts = (await historyNetwork.getReceipts(hash, header)).valueOr:
          raise newException(ValueError, "Could not find receipts for requested hash")

        logs = deriveLogs(header, body.transactions, receipts)
        filteredLogs = filterLogs(logs, filterOptions.address, filterOptions.topics)

      return filteredLogs
    else:
      # bloomfilter returned false, there are no logs matching the criteria
      return @[]

  rpcServerWithProxy.rpc("eth_getBalance") do(
    data: web3Types.Address, quantityTag: RtBlockIdentifier
  ) -> UInt256:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    let
      blockNumber = quantityTag.number.uint64
      blockHash = (await historyNetwork.getBlockHashByNumber(blockNumber)).valueOr:
        raise newException(ValueError, "Unable to get block hash")

      balance = (await sn.getBalance(blockHash, data.EthAddress)).valueOr:
        raise newException(ValueError, "Unable to get balance")

    return balance

  rpcServerWithProxy.rpc("eth_getTransactionCount") do(
    data: web3Types.Address, quantityTag: RtBlockIdentifier
  ) -> Quantity:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the number of transactions send from this address.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    let
      blockNumber = quantityTag.number.uint64
      blockHash = (await historyNetwork.getBlockHashByNumber(blockNumber)).valueOr:
        raise newException(ValueError, "Unable to get block hash")

      nonce = (await sn.getTransactionCount(blockHash, data.EthAddress)).valueOr:
        raise newException(ValueError, "Unable to get transaction count")
    return nonce.Quantity

  rpcServerWithProxy.rpc("eth_getStorageAt") do(
    data: web3Types.Address, slot: UInt256, quantityTag: RtBlockIdentifier
  ) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## slot: integer of the position in the storage.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the value at this storage position.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    let
      blockNumber = quantityTag.number.uint64
      blockHash = (await historyNetwork.getBlockHashByNumber(blockNumber)).valueOr:
        raise newException(ValueError, "Unable to get block hash")

      slotValue = (await sn.getStorageAt(blockHash, data.EthAddress, slot)).valueOr:
        raise newException(ValueError, "Unable to get storage slot")
    return FixedBytes[32](slotValue.toBytesBE())

  rpcServerWithProxy.rpc("eth_getCode") do(
    data: web3Types.Address, quantityTag: RtBlockIdentifier
  ) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    let
      blockNumber = quantityTag.number.uint64
      blockHash = (await historyNetwork.getBlockHashByNumber(blockNumber)).valueOr:
        raise newException(ValueError, "Unable to get block hash")

      bytecode = (await sn.getCode(blockHash, data.EthAddress)).valueOr:
        raise newException(ValueError, "Unable to get code")
    return bytecode.asSeq()

  rpcServerWithProxy.rpc("eth_getProof") do(
    data: web3Types.Address, slots: seq[UInt256], quantityTag: RtBlockIdentifier
  ) -> ProofResponse:
    ## Returns information about an account and storage slots along with account
    ## and storage proofs which prove the existence of the values in the state.
    ## See spec here: https://eips.ethereum.org/EIPS/eip-1186
    ##
    ## data: address of the account.
    ## slots: integers of the positions in the storage to return.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the proof response containing the account, account proof and storage proof

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    let
      blockNumber = quantityTag.number.uint64
      blockHash = (await historyNetwork.getBlockHashByNumber(blockNumber)).valueOr:
        raise newException(ValueError, "Unable to get block hash")
      proofs = (await sn.getProofs(blockHash, data.EthAddress, slots)).valueOr:
        raise newException(ValueError, "Unable to get proofs")

    var storageProof = newSeqOfCap[StorageProof](slots.len)
    for i, slot in slots:
      let (slotKey, slotValue) = proofs.slots[i]
      storageProof.add(
        StorageProof(
          key: slotKey,
          value: slotValue,
          proof: seq[RlpEncodedBytes](proofs.slotProofs[i]),
        )
      )

    return ProofResponse(
      address: data,
      accountProof: seq[RlpEncodedBytes](proofs.accountProof),
      balance: proofs.account.balance,
      nonce: web3types.Quantity(proofs.account.nonce),
      codeHash: web3types.Hash256(proofs.account.codeHash.data),
      storageHash: web3types.Hash256(proofs.account.storageRoot.data),
      storageProof: storageProof,
    )

  # TODO: Should we move these debug methods into a separate debug rpcServer?

  rpcServerWithProxy.rpc("debug_getBalanceByStateRoot") do(
    data: web3Types.Address, stateRoot: web3types.Hash256
  ) -> UInt256:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## stateRoot: the state root used to search the state trie.
    ## Returns integer of the current balance in wei.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let balance = (
      await sn.getBalanceByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get balance")

    return balance

  rpcServerWithProxy.rpc("debug_getTransactionCountByStateRoot") do(
    data: web3Types.Address, stateRoot: web3types.Hash256
  ) -> Quantity:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## stateRoot: the state root used to search the state trie.
    ## Returns integer of the number of transactions send from this address.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let nonce = (
      await sn.getTransactionCountByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get transaction count")
    return nonce.Quantity

  rpcServerWithProxy.rpc("debug_getStorageAtByStateRoot") do(
    data: web3Types.Address, slot: UInt256, stateRoot: web3types.Hash256
  ) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## slot: integer of the position in the storage.
    ## stateRoot: the state root used to search the state trie.
    ## Returns: the value at this storage position.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let slotValue = (
      await sn.getStorageAtByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress, slot
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get storage slot")
    return FixedBytes[32](slotValue.toBytesBE())

  rpcServerWithProxy.rpc("debug_getCodeByStateRoot") do(
    data: web3Types.Address, stateRoot: web3types.Hash256
  ) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## stateRoot: the state root used to search the state trie.
    ## Returns the code from the given address.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let bytecode = (
      await sn.getCodeByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get code")

    return bytecode.asSeq()

  rpcServerWithProxy.rpc("debug_getProofByStateRoot") do(
    data: web3Types.Address, slots: seq[UInt256], stateRoot: web3types.Hash256
  ) -> ProofResponse:
    ## Returns information about an account and storage slots along with account
    ## and storage proofs which prove the existence of the values in the state.
    ##
    ## data: address of the account.
    ## slots: integers of the positions in the storage to return.
    ## stateRoot: the state root used to search the state trie.
    ## Returns: the proof response containing the account, account proof and storage proof

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let proofs = (
      await sn.getProofsByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress, slots
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get proofs")

    var storageProof = newSeqOfCap[StorageProof](slots.len)
    for i, slot in slots:
      let (slotKey, slotValue) = proofs.slots[i]
      storageProof.add(
        StorageProof(
          key: slotKey,
          value: slotValue,
          proof: seq[RlpEncodedBytes](proofs.slotProofs[i]),
        )
      )

    return ProofResponse(
      address: data,
      accountProof: seq[RlpEncodedBytes](proofs.accountProof),
      balance: proofs.account.balance,
      nonce: web3types.Quantity(proofs.account.nonce),
      codeHash: web3types.Hash256(proofs.account.codeHash.data),
      storageHash: web3types.Hash256(proofs.account.storageRoot.data),
      storageProof: storageProof,
    )

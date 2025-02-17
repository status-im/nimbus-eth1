# Fluffy
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  json_rpc/rpcserver,
  chronicles,
  web3/[eth_api_types, conversions],
  eth/common/transaction_utils,
  beacon_chain/spec/forks,
  ../network/history/[history_network, history_content],
  ../network/state/[state_network, state_content, state_endpoints],
  ../network/beacon/beacon_light_client,
  ../version

from ../../execution_chain/errors import ValidationError
from ../../execution_chain/rpc/filters import headerBloomFilter, deriveLogs

from eth/common/eth_types_rlp import rlpHash

export rpcserver

# See the list of Ethereum execution JSON-RPC APIs which will be supported by
# Portal Network clients such as Fluffy:
# https://github.com/ethereum/portal-network-specs?tab=readme-ov-file#the-json-rpc-api

func init*(
    T: type TransactionObject,
    tx: transactions.Transaction,
    header: Header,
    txIndex: int,
): T {.raises: [ValidationError].} =
  let sender = tx.recoverSender().valueOr:
    raise (ref ValidationError)(msg: "Invalid tx signature")

  TransactionObject(
    blockHash: Opt.some(header.rlpHash),
    blockNumber: Opt.some(Quantity(header.number)),
    `from`: sender,
    gas: Quantity(tx.gasLimit),
    gasPrice: Quantity(tx.gasPrice),
    hash: tx.rlpHash,
    input: tx.payload,
    nonce: Quantity(tx.nonce),
    to: Opt.some(tx.destination),
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
    T: type BlockObject, header: Header, body: BlockBody, fullTx = true, isUncle = false
): T {.raises: [ValidationError].} =
  let blockHash = header.rlpHash

  var blockObject = BlockObject(
    number: Quantity(header.number),
    hash: blockHash,
    parentHash: header.parentHash,
    nonce: Opt.some(FixedBytes[8](header.nonce)),
    sha3Uncles: header.ommersHash,
    logsBloom: FixedBytes[256] header.logsBloom,
    transactionsRoot: header.txRoot,
    stateRoot: header.stateRoot,
    receiptsRoot: header.receiptsRoot,
    miner: header.coinbase,
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

  # TODO: This was copied from `rpc_utils`, but the block size calculation does
  # not make sense. TO FIX.
  let size = sizeof(Header) - sizeof(seq[byte]) + header.extraData.len
  blockObject.size = Quantity(size.uint)

  if not isUncle:
    blockObject.uncles = body.uncles.map(
      proc(h: Header): Hash32 =
        h.rlpHash
    )

    if fullTx:
      var i = 0
      for tx in body.transactions:
        blockObject.transactions.add txOrHash(TransactionObject.init(tx, header, i))
        inc i
    else:
      for tx in body.transactions:
        blockObject.transactions.add txOrHash(rlpHash(tx))

  blockObject

template getOrRaise(historyNetwork: Opt[HistoryNetwork]): HistoryNetwork =
  let hn = historyNetwork.valueOr:
    raise newException(ValueError, "history sub-network not enabled")
  hn

template getOrRaise(beaconLightClient: Opt[LightClient]): LightClient =
  let sn = beaconLightClient.valueOr:
    raise newException(ValueError, "beacon sub-network not enabled")
  sn

template getOrRaise(stateNetwork: Opt[StateNetwork]): StateNetwork =
  let sn = stateNetwork.valueOr:
    raise newException(ValueError, "state sub-network not enabled")
  sn

proc installEthApiHandlers*(
    rpcServer: RpcServer,
    historyNetwork: Opt[HistoryNetwork],
    beaconLightClient: Opt[LightClient],
    stateNetwork: Opt[StateNetwork],
) =
  rpcServer.rpc("web3_clientVersion") do() -> string:
    return clientVersion

  rpcServer.rpc("eth_chainId") do() -> Quantity:
    # The Portal Network can only support MainNet at the moment, so always return
    # 1
    return Quantity(uint64(1))

  rpcServer.rpc("eth_blockNumber") do() -> Quantity:
    let blc = beaconLightClient.getOrRaise()

    withForkyStore(blc.store[]):
      when lcDataFork > LightClientDataFork.Altair:
        return Quantity(forkyStore.optimistic_header.execution.block_number)
      else:
        raise newException(ValueError, "Not available before Capella - not synced?")

  rpcServer.rpc("eth_getBlockByHash") do(
    blockHash: Hash32, fullTransactions: bool
  ) -> Opt[BlockObject]:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if
    ## false only the hashes of the transactions.
    ##
    ## Returns BlockObject or nil when no block was found.
    let
      hn = historyNetwork.getOrRaise()
      (header, body) = (await hn.getBlock(blockHash)).valueOr:
        return Opt.none(BlockObject)

    return Opt.some(BlockObject.init(header, body, fullTransactions))

  rpcServer.rpc("eth_getBlockByNumber") do(
    quantityTag: RtBlockIdentifier, fullTransactions: bool
  ) -> Opt[BlockObject]:
    let hn = historyNetwork.getOrRaise()

    if quantityTag.kind == bidAlias:
      let tag = quantityTag.alias.toLowerAscii
      case tag
      of "latest":
        let blc = beaconLightClient.getOrRaise()

        withForkyStore(blc.store[]):
          when lcDataFork > LightClientDataFork.Altair:
            let
              blockHash = forkyStore.optimistic_header.execution.block_hash.to(Hash32)
              (header, body) = (await hn.getBlock(blockHash)).valueOr:
                return Opt.none(BlockObject)

            return Opt.some(BlockObject.init(header, body, fullTransactions))
          else:
            raise newException(ValueError, "Not available before Capella - not synced?")
      of "earliest":
        raise newException(ValueError, "Earliest tag not yet implemented")
      of "safe":
        # Safe block currently means most recent justified block, see:
        # - https://github.com/ethereum/consensus-specs/blob/4afe39822c9ad9747e0f5635cca117c18441ec1b/fork_choice/safe-block.md
        # - https://github.com/status-im/nimbus-eth2/blob/4e440277cf8a3fed72f32eb2f01fc5e910ad6768/beacon_chain/consensus_object_pools/attestation_pool.nim#L1162
        # This is provided by engineForkChoiceUpdateV1/V2/V3 from CL to EL.
        # Unclear how to get the block hash from current Portal network.
        raise newException(ValueError, "safe tag cannot be implemented")
      of "finalized":
        let blc = beaconLightClient.getOrRaise()

        withForkyStore(blc.store[]):
          when lcDataFork > LightClientDataFork.Altair:
            let
              blockHash = forkyStore.finalized_header.execution.block_hash.to(Hash32)
              (header, body) = (await hn.getBlock(blockHash)).valueOr:
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
        (header, body) = (await hn.getBlock(blockNumber)).valueOr:
          return Opt.none(BlockObject)

      return Opt.some(BlockObject.init(header, body, fullTransactions))

  rpcServer.rpc("eth_getBlockTransactionCountByHash") do(blockHash: Hash32) -> Quantity:
    ## Returns the number of transactions in a block from a block matching the
    ## given block hash.
    ##
    ## data: hash of a block
    ## Returns integer of the number of transactions in this block.
    let
      hn = historyNetwork.getOrRaise()
      (_, body) = (await hn.getBlock(blockHash)).valueOr:
        raise newException(ValueError, "Could not find block with requested hash")

    var txCount: uint = 0
    for tx in body.transactions:
      txCount.inc()

    return Quantity(txCount)

  # Note: can't implement this yet as the fluffy node doesn't know the relation
  # of tx hash -> block number -> block hash, in order to get the receipt
  # from from the block with that block hash. The Canonical Indices Network
  # would need to be implemented to get this information.
  # rpcServer.rpc("eth_getTransactionReceipt") do(
  #     data: EthHashStr) -> Opt[ReceiptObject]:

  rpcServer.rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[LogObject]:
    if filterOptions.blockHash.isNone():
      # Currently only queries by blockhash are supported.
      # TODO: Can impolement range queries by block number now.
      raise newException(
        ValueError,
        "Unsupported query: Only `blockHash` queries are currently supported",
      )

    let
      hn = historyNetwork.getOrRaise()
      hash = filterOptions.blockHash.value()
      header = (await hn.getVerifiedBlockHeader(hash)).valueOr:
        raise newException(ValueError, "Could not find header with requested hash")

    if headerBloomFilter(header, filterOptions.address, filterOptions.topics):
      # TODO: These queries could be done concurrently, investigate if there
      # are no assumptions about usage of concurrent queries on portal
      # wire protocol level
      let
        body = (await hn.getBlockBody(hash, header)).valueOr:
          raise newException(ValueError, "Could not find block body for requested hash")
        receipts = (await hn.getReceipts(hash, header)).valueOr:
          raise newException(ValueError, "Could not find receipts for requested hash")

      return deriveLogs(header, body.transactions, receipts, filterOptions)
    else:
      # bloomfilter returned false, there are no logs matching the criteria
      return @[]

  rpcServer.rpc("eth_getBalance") do(
    data: Address, quantityTag: RtBlockIdentifier
  ) -> UInt256:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    # This endpoint requires history network to be enabled in order to look up
    # the state root by block number in the call to getBalance
    discard historyNetwork.getOrRaise()

    let
      sn = stateNetwork.getOrRaise()
      blockNumber = quantityTag.number.uint64
      balance = (await sn.getBalance(blockNumber, data)).valueOr:
        raise newException(ValueError, "Unable to get balance")

    return balance

  rpcServer.rpc("eth_getTransactionCount") do(
    data: Address, quantityTag: RtBlockIdentifier
  ) -> Quantity:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the number of transactions send from this address.

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    # This endpoint requires history network to be enabled in order to look up
    # the state root by block number in the call to getTransactionCount
    discard historyNetwork.getOrRaise()

    let
      sn = stateNetwork.getOrRaise()
      blockNumber = quantityTag.number.uint64
      nonce = (await sn.getTransactionCount(blockNumber, data)).valueOr:
        raise newException(ValueError, "Unable to get transaction count")
    return nonce.Quantity

  rpcServer.rpc("eth_getStorageAt") do(
    data: Address, slot: UInt256, quantityTag: RtBlockIdentifier
  ) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## slot: integer of the position in the storage.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the value at this storage position.

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    # This endpoint requires history network to be enabled in order to look up
    # the state root by block number in the call to getStorageAt
    discard historyNetwork.getOrRaise()

    let
      sn = stateNetwork.getOrRaise()
      blockNumber = quantityTag.number.uint64
      slotValue = (await sn.getStorageAt(blockNumber, data, slot)).valueOr:
        raise newException(ValueError, "Unable to get storage slot")
    return FixedBytes[32](slotValue.toBytesBE())

  rpcServer.rpc("eth_getCode") do(
    data: Address, quantityTag: RtBlockIdentifier
  ) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    # This endpoint requires history network to be enabled in order to look up
    # the state root by block number in the call to getCode
    discard historyNetwork.getOrRaise()

    let
      sn = stateNetwork.getOrRaise()
      blockNumber = quantityTag.number.uint64
      bytecode = (await sn.getCode(blockNumber, data)).valueOr:
        raise newException(ValueError, "Unable to get code")
    return bytecode.asSeq()

  rpcServer.rpc("eth_getProof") do(
    data: Address, slots: seq[UInt256], quantityTag: RtBlockIdentifier
  ) -> ProofResponse:
    ## Returns information about an account and storage slots along with account
    ## and storage proofs which prove the existence of the values in the state.
    ## See spec here: https://eips.ethereum.org/EIPS/eip-1186
    ##
    ## data: address of the account.
    ## slots: integers of the positions in the storage to return.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns: the proof response containing the account, account proof and storage proof

    if quantityTag.kind == bidAlias:
      # TODO: Implement
      raise newException(ValueError, "tag not yet implemented")

    # This endpoint requires history network to be enabled in order to look up
    # the state root by block number in the call to getProof
    discard historyNetwork.getOrRaise()

    let
      sn = stateNetwork.getOrRaise()
      blockNumber = quantityTag.number.uint64
      proofs = (await sn.getProofs(blockNumber, data, slots)).valueOr:
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
      nonce: Quantity(proofs.account.nonce),
      codeHash: proofs.account.codeHash,
      storageHash: proofs.account.storageRoot,
      storageProof: storageProof,
    )

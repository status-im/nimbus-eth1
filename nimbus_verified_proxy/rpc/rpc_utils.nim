# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/[base_rlp, headers_rlp, blocks, hashes],
  stint,
  web3/eth_api_types,
  web3/engine_api_types,
  ../../nimbus/db/core_db

export eth_api_types, engine_api_types

type ExecutionData* = object
  parentHash*: Hash32
  feeRecipient*: Address
  stateRoot*: Hash32
  receiptsRoot*: Hash32
  logsBloom*: FixedBytes[256]
  prevRandao*: FixedBytes[32]
  blockNumber*: Quantity
  gasLimit*: Quantity
  gasUsed*: Quantity
  timestamp*: Quantity
  extraData*: DynamicBytes[0, 32]
  baseFeePerGas*: UInt256
  blockHash*: Hash32
  transactions*: seq[TypedTransaction]
  withdrawals*: seq[WithdrawalV1]

proc asExecutionData*(payload: SomeExecutionPayload): ExecutionData =
  when payload is ExecutionPayloadV1:
    return ExecutionData(
      parentHash: payload.parentHash,
      feeRecipient: payload.feeRecipient,
      stateRoot: payload.stateRoot,
      receiptsRoot: payload.receiptsRoot,
      logsBloom: payload.logsBloom,
      prevRandao: payload.prevRandao,
      blockNumber: payload.blockNumber,
      gasLimit: payload.gasLimit,
      gasUsed: payload.gasUsed,
      timestamp: payload.timestamp,
      extraData: payload.extraData,
      baseFeePerGas: payload.baseFeePerGas,
      blockHash: payload.blockHash,
      transactions: payload.transactions,
      withdrawals: @[],
    )
  else:
    # TODO: Deal with different payload types
    return ExecutionData(
      parentHash: payload.parentHash,
      feeRecipient: payload.feeRecipient,
      stateRoot: payload.stateRoot,
      receiptsRoot: payload.receiptsRoot,
      logsBloom: payload.logsBloom,
      prevRandao: payload.prevRandao,
      blockNumber: payload.blockNumber,
      gasLimit: payload.gasLimit,
      gasUsed: payload.gasUsed,
      timestamp: payload.timestamp,
      extraData: payload.extraData,
      baseFeePerGas: payload.baseFeePerGas,
      blockHash: payload.blockHash,
      transactions: payload.transactions,
      withdrawals: payload.withdrawals,
    )

proc calculateTransactionData(
    items: openArray[TypedTransaction]
): (Hash32, seq[TxOrHash], uint64) =
  ## returns tuple composed of
  ## - root of transactions trie
  ## - list of transactions hashes
  ## - total size of transactions in block
  var tr = newCoreDbRef(DefaultDbMemory).ctx.getGeneric()
  var txHashes: seq[TxOrHash]
  var txSize: uint64
  for i, t in items:
    let tx = distinctBase(t)
    txSize = txSize + uint64(len(tx))
    tr.merge(rlp.encode(uint64 i), tx).expect "merge data"
    txHashes.add(txOrHash keccak256(tx))
  let rootHash = tr.state(updateOk = true).expect "hash"
  (rootHash, txHashes, txSize)

func blockHeaderSize(payload: ExecutionData, txRoot: Hash32): uint64 =
  let header = Header(
    parentHash: payload.parentHash,
    ommersHash: EMPTY_UNCLE_HASH,
    coinbase: payload.feeRecipient,
    stateRoot: payload.stateRoot,
    transactionsRoot: txRoot,
    receiptsRoot: payload.receiptsRoot,
    logsBloom: payload.logsBloom,
    difficulty: default(DifficultyInt),
    number: distinctBase(payload.blockNumber),
    gasLimit: distinctBase(payload.gasLimit),
    gasUsed: distinctBase(payload.gasUsed),
    timestamp: payload.timestamp.EthTime,
    extraData: payload.extraData.data,
    mixHash: payload.prevRandao,
    nonce: default(Bytes8),
    baseFeePerGas: Opt.some payload.baseFeePerGas,
  )
  return uint64(len(rlp.encode(header)))

proc asBlockObject*(p: ExecutionData): BlockObject {.raises: [ValueError].} =
  # TODO: currently we always calculate txHashes as BlockObject does not have
  # option of returning full transactions. It needs fixing at nim-web3 library
  # level
  let (txRoot, txHashes, txSize) = calculateTransactionData(p.transactions)
  let headerSize = blockHeaderSize(p, txRoot)
  let blockSize = txSize + headerSize
  BlockObject(
    number: p.blockNumber,
    hash: p.blockHash,
    parentHash: p.parentHash,
    sha3Uncles: EMPTY_UNCLE_HASH,
    logsBloom: p.logsBloom,
    transactionsRoot: txRoot,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    miner: p.feeRecipient,
    difficulty: UInt256.zero,
    extraData: fromHex(DynamicBytes[0, 4096], p.extraData.toHex),
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    nonce: Opt.some(default(Bytes8)),
    size: Quantity(blockSize),
    # TODO: It does not matter what we put here after merge blocks.
    # Other projects like `helios` return `0`, data providers like alchemy return
    # transition difficulty. For now retruning `0` as this is a bit easier to do.
    totalDifficulty: UInt256.zero,
    transactions: txHashes,
    uncles: @[],
    baseFeePerGas: Opt.some(p.baseFeePerGas),
  )

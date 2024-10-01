# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/typetraits,
  eth/common/eth_types as etypes,
  eth/rlp,
  nimcrypto/hash,
  stint,
  web3,
  web3/engine_api_types,
  ../../nimbus/db/core_db

type
  FixedBytes[N: static int] = primitives.FixedBytes[N]
  Address = primitives.Address

type ExecutionData* = object
  parentHash*: BlockHash
  feeRecipient*: Address
  stateRoot*: BlockHash
  receiptsRoot*: BlockHash
  logsBloom*: FixedBytes[256]
  prevRandao*: FixedBytes[32]
  blockNumber*: Quantity
  gasLimit*: Quantity
  gasUsed*: Quantity
  timestamp*: Quantity
  extraData*: DynamicBytes[0, 32]
  baseFeePerGas*: UInt256
  blockHash*: BlockHash
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

func toFixedBytes(d: MDigest[256]): FixedBytes[32] =
  FixedBytes[32](d.data)

template asEthHash(hash: BlockHash): etypes.Hash256 =
  etypes.Hash256(distinctBase(hash))

proc calculateTransactionData(
    items: openArray[TypedTransaction]
): (etypes.Hash256, seq[TxOrHash], uint64) =
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
    txHashes.add(txOrHash toFixedBytes(keccakHash(tx)))
  let rootHash = tr.state(updateOk = true).expect "hash"
  (rootHash, txHashes, txSize)

func blockHeaderSize(payload: ExecutionData, txRoot: etypes.Hash256): uint64 =
  let bh = etypes.BlockHeader(
    parentHash: payload.parentHash.asEthHash,
    ommersHash: etypes.EMPTY_UNCLE_HASH,
    coinbase: etypes.EthAddress payload.feeRecipient,
    stateRoot: payload.stateRoot.asEthHash,
    transactionsRoot: txRoot,
    receiptsRoot: payload.receiptsRoot.asEthHash,
    logsBloom: distinctBase(payload.logsBloom).to(Bloom),
    difficulty: default(etypes.DifficultyInt),
    number: payload.blockNumber.distinctBase,
    gasLimit: distinctBase(payload.gasLimit),
    gasUsed: distinctBase(payload.gasUsed),
    timestamp: payload.timestamp.EthTime,
    extraData: bytes payload.extraData,
    mixHash: payload.prevRandao.asEthHash,
    nonce: default(etypes.BlockNonce),
    baseFeePerGas: Opt.some payload.baseFeePerGas,
  )
  return uint64(len(rlp.encode(bh)))

proc asBlockObject*(p: ExecutionData): BlockObject {.raises: [ValueError].} =
  # TODO: currently we always calculate txHashes as BlockObject does not have
  # option of returning full transactions. It needs fixing at nim-web3 library
  # level
  let (txRoot, txHashes, txSize) = calculateTransactionData(p.transactions)
  let headerSize = blockHeaderSize(p, txRoot)
  let blockSize = txSize + headerSize
  BlockObject(
    number: web3.BlockNumber p.blockNumber,
    hash: p.blockHash,
    parentHash: p.parentHash,
    sha3Uncles: FixedBytes(etypes.EMPTY_UNCLE_HASH.data),
    logsBloom: p.logsBloom,
    transactionsRoot: toFixedBytes(txRoot),
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    miner: p.feeRecipient,
    difficulty: UInt256.zero,
    extraData: fromHex(DynamicBytes[0, 4096], p.extraData.toHex),
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    nonce: Opt.some(default(FixedBytes[8])),
    size: Quantity(blockSize),
    # TODO: It does not matter what we put here after merge blocks.
    # Other projects like `helios` return `0`, data providers like alchemy return
    # transition difficulty. For now retruning `0` as this is a bit easier to do.
    totalDifficulty: UInt256.zero,
    transactions: txHashes,
    uncles: @[],
    baseFeePerGas: Opt.some(p.baseFeePerGas),
  )

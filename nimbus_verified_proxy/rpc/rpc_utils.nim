# nimbus_verified_proxy
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/typetraits,
  eth/common/eth_types as etypes,
  eth/[trie, rlp, trie/db],
  stint,
  web3

template unsafeQuantityToInt64(q: Quantity): int64 =
  int64 q

func toFixedBytes(d: MDigest[256]): FixedBytes[32] =
  FixedBytes[32](d.data)

template asEthHash(hash: BlockHash): Hash256 =
  Hash256(data: distinctBase(hash))

proc calculateTransactionData(
    items: openArray[TypedTransaction]):
    (etypes.Hash256, seq[TxHash], uint64) {.raises: [Defect, RlpError].} =
  ## returns tuple composed of
  ## - root of transactions trie
  ## - list of transactions hashes
  ## - total size of transactions in block
  var tr = initHexaryTrie(newMemoryDB())
  var txHashes: seq[TxHash]
  var txSize: uint64
  for i, t in items:
    let tx = distinctBase(t)
    txSize = txSize + uint64(len(tx))
    tr.put(rlp.encode(i), tx)
    txHashes.add(toFixedBytes(keccakHash(tx)))
  return (tr.rootHash(), txHashes, txSize)

func blockHeaderSize(
    payload: ExecutionPayloadV1, txRoot: etypes.Hash256): uint64 =
  let bh = etypes.BlockHeader(
    parentHash    : payload.parentHash.asEthHash,
    ommersHash    : etypes.EMPTY_UNCLE_HASH,
    coinbase      : etypes.EthAddress payload.feeRecipient,
    stateRoot     : payload.stateRoot.asEthHash,
    txRoot        : txRoot,
    receiptRoot   : payload.receiptsRoot.asEthHash,
    bloom         : distinctBase(payload.logsBloom),
    difficulty    : default(etypes.DifficultyInt),
    blockNumber   : payload.blockNumber.distinctBase.u256,
    gasLimit      : payload.gasLimit.unsafeQuantityToInt64,
    gasUsed       : payload.gasUsed.unsafeQuantityToInt64,
    timestamp     : fromUnix payload.timestamp.unsafeQuantityToInt64,
    extraData     : bytes payload.extraData,
    mixDigest     : payload.prevRandao.asEthHash,
    nonce         : default(etypes.BlockNonce),
    fee           : some payload.baseFeePerGas
  )
  return uint64(len(rlp.encode(bh)))

proc asBlockObject*(
    p: ExecutionPayloadV1): BlockObject {.raises: [Defect, RlpError].} =
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
    sha3Uncles: FixedBytes(etypes.EMPTY_UNCLE_HASH.data),
    logsBloom: p.logsBloom,
    transactionsRoot: toFixedBytes(txRoot),
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    miner: p.feeRecipient,
    difficulty: UInt256.zero,
    extraData: p.extraData.toHex,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    nonce: some(default(FixedBytes[8])),
    size: Quantity(blockSize),
    # TODO: It does not matter what we put here after merge blocks.
    # Other projects like `helios` return `0`, data providers like alchemy return
    # transition difficulty. For now retruning `0` as this is a bit easier to do.
    totalDifficulty: UInt256.zero,
    transactions: txHashes,
    uncles: @[],
    baseFeePerGas: some(p.baseFeePerGas)
  )


# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[sets, tables, times],
  eth/common,
  chronos,
  chronos/ratelimit,
  ../../core/[chain, tx_pool, pooled_txs],
  ../../networking/p2p_types

type
  Status68Packet* = object
    version*: uint64
    networkId*: NetworkId
    totalDifficulty*: DifficultyInt
    bestHash*: Hash32
    genesisHash*: Hash32
    forkId*: ChainForkId

  # https://github.com/ethereum/devp2p/blob/b0c213de97978053a0f62c3ea4d23c0a3d8784bc/caps/eth.md#status-0x00
  Status69Packet* = object
    version*: uint64
    networkId*: NetworkId
    genesisHash*: Hash32
    forkId*: ChainForkId
    earliest*: uint64 # earliest available full block
    latest*: uint64 # latest available full block
    latestHash*: Hash32 # hash of latest available full block

  BlockHeadersPacket* = object
    headers*: seq[Header]

  BlockBodiesPacket* = object
    bodies*: seq[BlockBody]

  PooledTransactionsPacket* = object
    transactions*: seq[PooledTransaction]

  ReceiptsPacket* = object
    receipts*: seq[seq[Receipt]]

  NewBlockHashesPacket* = object
    hashes*: seq[NewBlockHashesAnnounce]

  NewBlockPacket* = object
    blk*: EthBlock
    totalDifficulty*: DifficultyInt

  TransactionsPacket* = ref object
    transactions*: seq[Transaction]

  NewPooledTransactionHashesPacket* = ref object
    txTypes*: seq[byte]
    txSizes*: seq[uint64]
    txHashes*: seq[Hash32]

  NewBlockHashesAnnounce* = object
    hash*: Hash32
    number*: base.BlockNumber

  ChainForkId* = object
    forkHash*: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext*: uint64         # The RLP encoding must be variable-length

  Eth68State* = object
    totalDifficulty*: DifficultyInt
    genesisHash*: Hash32
    bestBlockHash*: Hash32
    forkId*: ChainForkId

  Eth69State* = object
    genesisHash*: Hash32
    forkId*: ChainForkId
    earliest*: uint64
    latest*: uint64
    latestHash*: Hash32

  EthPeerState* = ref object of RootRef
    initialized*: bool

  Eth69PeerState* = ref object of EthPeerState
    earliest*: uint64
    latest*: uint64
    latestHash*: Hash32

  BlockHeadersRequest* = object
    startBlock*: BlockHashOrNumber
    maxResults*, skip*: uint
    reverse*: bool

  BlockBodiesRequest* = object
    blockHashes*: seq[Hash32]

  PooledTransactionsRequest* = object
    txHashes*: seq[Hash32]

  ReceiptsRequest* = object
    blockHashes*: seq[Hash32]

  StoredReceiptsPacket* = object
    receipts*: seq[seq[StoredReceipt]]

  BlockRangeUpdatePacket* = object
    earliest*: uint64
    latest*: uint64
    latestHash*: Hash32

  SeenObject* = ref object
    lastSeen*: Time
    peers*: HashSet[NodeId]

  ActionHandler* = proc(): Future[void] {.async: (raises: [CancelledError]).}

  EthWireRef* = ref object of RootRef
    chain* : ForkedChainRef
    txPool*: TxPoolRef
    node*  : EthereumNode
    quota* : TokenBucket
    seenTransactions*: Table[Hash32, SeenObject]
    tickerHeartbeat*: Future[void].Raising([CancelledError])
    actionHeartbeat*: Future[void].Raising([CancelledError])
    actionQueue*: AsyncQueue[ActionHandler]
    gossipEnabled*: bool

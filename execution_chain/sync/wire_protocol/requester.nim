# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronos,
  eth/common,
  ./types,
  ../../networking/rlpx,
  ../../networking/p2p_types

export
  common,
  chronos,
  types,
  rlpx,
  p2p_types

defineProtocol(PROTO = eth68,
               version = 68,
               rlpxName = "eth",
               peerState = EthPeerState,
               networkState = EthWireRef)

defineProtocol(PROTO = eth69,
               version = 69,
               rlpxName = "eth",
               peerState = EthPeerState,
               networkState = EthWireRef)

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

  TransactionsPacket* = object
    transactions*: seq[Transaction]

  NewPooledTransactionHashesPacket* = object
    txTypes*: seq[byte]
    txSizes*: seq[uint64]
    txHashes*: seq[Hash32]

  BlockRangeUpdatePacket* = object
    earliest*: uint64
    latest*: uint64
    latestHash*: uint64

const
  StatusMsg*                     =  0'u64
  NewBlockHashesMsg*             =  1'u64
  TransactionMsg*                =  2'u64
  GetBlockHeadersMsg*            =  3'u64
  BlockHeadersMsg*               =  4'u64
  GetBlockBodiesMsg*             =  5'u64
  BlockBodiesMsg*                =  6'u64
  NewBlockMsg*                   =  7'u64
  NewPooledTransactionHashesMsg* =  8'u64
  GetPooledTransactionsMsg*      =  9'u64
  PooledTransactionsMsg*         = 10'u64
  GetReceiptsMsg*                = 15'u64
  ReceiptsMsg*                   = 16'u64
  # https://github.com/ethereum/devp2p/blob/b0c213de97978053a0f62c3ea4d23c0a3d8784bc/caps/eth.md#blockrangeupdate-0x11
  BlockRangeUpdateMsg*           = 0x11'u64

proc status68*(peer: Peer; packet: Status68Packet;
             timeout: Duration = milliseconds(10000'i64)):
              Future[Status68Packet] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  let
    sendingFut = eth68.rlpxSendMessage(peer, StatusMsg,
                    packet.version,
                    packet.networkId,
                    packet.totalDifficulty,
                    packet.bestHash,
                    packet.genesisHash,
                    packet.forkId)

    responseFut = eth68.nextMsg(peer, Status68Packet, StatusMsg)
  handshakeImpl[Status68Packet](peer, sendingFut, responseFut, timeout)

proc status69*(peer: Peer; packet: Status69Packet;
             timeout: Duration = milliseconds(10000'i64)):
              Future[Status69Packet] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  let
    sendingFut = eth69.rlpxSendMessage(peer, StatusMsg,
                    packet.version,
                    packet.networkId,
                    packet.genesisHash,
                    packet.forkId,
                    packet.earliest,
                    packet.latest,
                    packet.latestHash)

    responseFut = eth69.nextMsg(peer, Status69Packet, StatusMsg)
  handshakeImpl[Status69Packet](peer, sendingFut, responseFut, timeout)

proc transactions*(peer: Peer; transactions: openArray[Transaction]): Future[
    void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if peer.supports(eth69):
    eth69.rlpxSendMessage(peer, TransactionMsg, transactions)
  else:
    eth68.rlpxSendMessage(peer, TransactionMsg, transactions)

proc getBlockHeaders*(peer: Peer; request: BlockHeadersRequest;
                      timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[BlockHeadersPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                       raw: true).} =
  if peer.supports(eth69):
    eth69.rlpxSendRequest(peer, GetBlockHeadersMsg, request)
  else:
    eth68.rlpxSendRequest(peer, GetBlockHeadersMsg, request)

proc blockHeaders*(responder: Responder;
                   headers: openArray[Header]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if responder.supports(eth69):
    eth69.rlpxSendMessage(responder, BlockHeadersMsg, headers)
  else:
    eth68.rlpxSendMessage(responder, BlockHeadersMsg, headers)

proc getBlockBodies*(peer: Peer; packet: BlockBodiesRequest;
                     timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[BlockBodiesPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                      raw: true).} =
  if peer.supports(eth69):
    eth69.rlpxSendRequest(peer, GetBlockBodiesMsg, packet.blockHashes)
  else:
    eth68.rlpxSendRequest(peer, GetBlockBodiesMsg, packet.blockHashes)

proc blockBodies*(responder: Responder;
                  bodies: openArray[BlockBody]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if responder.supports(eth69):
    eth69.rlpxSendMessage(responder, BlockBodiesMsg, bodies)
  else:
    eth68.rlpxSendMessage(responder, BlockBodiesMsg, bodies)

proc newPooledTransactionHashes*(peer: Peer; txTypes: seq[byte];
                                 txSizes: openArray[uint64];
                                 txHashes: openArray[Hash32]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if peer.supports(eth69):
    eth69.rlpxSendMessage(peer, NewPooledTransactionHashesMsg,
      txTypes, txSizes, txHashes)
  else:
    eth68.rlpxSendMessage(peer, NewPooledTransactionHashesMsg,
      txTypes, txSizes, txHashes)

proc getPooledTransactions*(peer: Peer; packet: PooledTransactionsRequest;
                            timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[PooledTransactionsPacket]] {.async: (
    raises: [CancelledError, EthP2PError], raw: true).} =
  if peer.supports(eth69):
    eth69.rlpxSendRequest(peer, GetPooledTransactionsMsg, packet.txHashes)
  else:
    eth68.rlpxSendRequest(peer, GetPooledTransactionsMsg, packet.txHashes)

proc pooledTransactions*(responder: Responder;
                         transactions: openArray[PooledTransaction]): Future[
    void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if responder.supports(eth69):
    eth69.rlpxSendMessage(responder, PooledTransactionsMsg, transactions)
  else:
    eth68.rlpxSendMessage(responder, PooledTransactionsMsg, transactions)

proc getReceipts*(peer: Peer; packet: ReceiptsRequest;
                  timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[ReceiptsPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                   raw: true).} =
  if peer.supports(eth69):
    eth69.rlpxSendRequest(peer, GetReceiptsMsg, packet.blockHashes)
  else:
    eth68.rlpxSendRequest(peer, GetReceiptsMsg, packet.blockHashes)

proc receipts*(responder: Responder;
               receipts: openArray[seq[Receipt]]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  doAssert(responder.supports(eth68), "'receipts' function only available for eth/68")
  eth68.rlpxSendMessage(responder, ReceiptsMsg, receipts)

proc blockRangeUpdate*(peer: Peer; packet: BlockRangeUpdatePacket): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  doAssert(peer.supports(eth69), "'blockRangeUpdate' function only available for eth/69")
  eth69.rlpxSendMessage(peer, BlockRangeUpdateMsg,
    packet.earliest, packet.latest, packet.latestHash)

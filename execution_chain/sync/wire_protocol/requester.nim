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

const
  protocolVersion* = 68

defineProtocol(PROTO = eth68,
               version = protocolVersion,
               rlpxName = "eth",
               peerState = EthPeerState,
               networkState = EthWireRef)

type
  StatusPacket* = object
    ethVersion*: uint64
    networkId*: NetworkId
    totalDifficulty*: DifficultyInt
    bestHash*: Hash32
    genesisHash*: Hash32
    forkId*: ChainForkId

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

proc status*(peer: Peer; packet: StatusPacket;
             timeout: Duration = milliseconds(10000'i64)):
              Future[StatusPacket] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  let
    sendingFut = eth68.rlpxSendMessage(peer, StatusMsg,
                    packet.ethVersion,
                    packet.networkId,
                    packet.totalDifficulty,
                    packet.bestHash,
                    packet.genesisHash,
                    packet.forkId)

    responseFut = eth68.nextMsg(peer, StatusPacket, StatusMsg)
  handshakeImpl[StatusPacket](peer, sendingFut, responseFut, timeout)

proc transactions*(peer: Peer; transactions: openArray[Transaction]): Future[
    void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  eth68.rlpxSendMessage(peer, TransactionMsg, transactions)

proc getBlockHeaders*(peer: Peer; request: BlockHeadersRequest;
                      timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[BlockHeadersPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                       raw: true).} =
  eth68.rlpxSendRequest(peer, GetBlockHeadersMsg, request)

proc blockHeaders*(responder: Responder;
                   headers: openArray[Header]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  eth68.rlpxSendMessage(responder, BlockHeadersMsg, headers)

proc getBlockBodies*(peer: Peer; packet: BlockBodiesRequest;
                     timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[BlockBodiesPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                      raw: true).} =
  eth68.rlpxSendRequest(peer, GetBlockBodiesMsg, packet.blockHashes)

proc blockBodies*(responder: Responder;
                  bodies: openArray[BlockBody]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  eth68.rlpxSendMessage(responder, BlockBodiesMsg, bodies)

proc newPooledTransactionHashes*(peer: Peer; txTypes: seq[byte];
                                 txSizes: openArray[uint64];
                                 txHashes: openArray[Hash32]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  eth68.rlpxSendMessage(peer, NewPooledTransactionHashesMsg,
    txTypes, txSizes, txHashes)

proc getPooledTransactions*(peer: Peer; packet: PooledTransactionsRequest;
                            timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[PooledTransactionsPacket]] {.async: (
    raises: [CancelledError, EthP2PError], raw: true).} =
  eth68.rlpxSendRequest(peer, GetPooledTransactionsMsg, packet.txHashes)

proc pooledTransactions*(responder: Responder;
                         transactions: openArray[PooledTransaction]): Future[
    void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  eth68.rlpxSendMessage(responder, PooledTransactionsMsg, transactions)

proc getReceipts*(peer: Peer; packet: ReceiptsRequest;
                  timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[ReceiptsPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                   raw: true).} =
  eth68.rlpxSendRequest(peer, GetReceiptsMsg, packet.blockHashes)

proc receipts*(responder: Responder;
               receipts: openArray[seq[Receipt]]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  eth68.rlpxSendMessage(responder, ReceiptsMsg, receipts)

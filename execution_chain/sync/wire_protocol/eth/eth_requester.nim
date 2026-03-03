# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  pkg/[chronos, eth/common],
  ../../../core/pooled_txs_rlp,
  ../../../networking/rlpx,
  ./eth_types

defineProtocol(PROTO = eth68,
               version = 68,
               rlpxName = "eth",
               PeerStateType = Eth68PeerState,
               NetworkStateType = EthWireRef)

defineProtocol(PROTO = eth69,
               version = 69,
               rlpxName = "eth",
               PeerStateType = Eth69PeerState,
               NetworkStateType = EthWireRef)

defineProtocol(PROTO = eth70,
               version = 70,
               rlpxName = "eth",
               PeerStateType = Eth69PeerState,
               NetworkStateType = EthWireRef)

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

func to*(rec: StoredReceiptsPacket, _: type ReceiptsPacket): ReceiptsPacket =
  for x in rec.receipts:
    result.receipts.add x.to(seq[Receipt])

func to*(rec: StoredReceipts70Packet, _: type ReceiptsPacket): ReceiptsPacket =
  for x in rec.receipts:
    result.receipts.add x.to(seq[Receipt])

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

proc status69OrLater*[PROTO](peer: Peer; packet: Status69Packet;
             timeout: Duration = milliseconds(10000'i64)):
              Future[Status69Packet] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  let
    sendingFut = PROTO.rlpxSendMessage(peer, StatusMsg,
                    packet.version,
                    packet.networkId,
                    packet.genesisHash,
                    packet.forkId,
                    packet.earliest,
                    packet.latest,
                    packet.latestHash)

    responseFut = PROTO.nextMsg(peer, Status69Packet, StatusMsg)
  handshakeImpl[Status69Packet](peer, sendingFut, responseFut, timeout)

proc transactions*(peer: Peer; transactions: openArray[Transaction]): Future[
    void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if peer.supports(eth70):
    eth70.rlpxSendMessage(peer, TransactionMsg, transactions)
  elif peer.supports(eth69):
    eth69.rlpxSendMessage(peer, TransactionMsg, transactions)
  else:
    eth68.rlpxSendMessage(peer, TransactionMsg, transactions)

proc getBlockHeaders*(peer: Peer; request: BlockHeadersRequest;
                      timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[BlockHeadersPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                       raw: true).} =
  if peer.supports(eth70):
    eth70.rlpxSendRequest(peer, timeout, GetBlockHeadersMsg, request)
  elif peer.supports(eth69):
    eth69.rlpxSendRequest(peer, timeout, GetBlockHeadersMsg, request)
  else:
    eth68.rlpxSendRequest(peer, timeout, GetBlockHeadersMsg, request)

proc blockHeaders*(responder: Responder;
                   headers: openArray[Header]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if responder.supports(eth70):
    eth70.rlpxSendMessage(responder, BlockHeadersMsg, headers)
  elif responder.supports(eth69):
    eth69.rlpxSendMessage(responder, BlockHeadersMsg, headers)
  else:
    eth68.rlpxSendMessage(responder, BlockHeadersMsg, headers)

proc getBlockBodies*(peer: Peer; packet: BlockBodiesRequest;
                     timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[BlockBodiesPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                      raw: true).} =
  if peer.supports(eth70):
    eth70.rlpxSendRequest(peer, timeout, GetBlockBodiesMsg, packet.blockHashes)
  elif peer.supports(eth69):
    eth69.rlpxSendRequest(peer, timeout, GetBlockBodiesMsg, packet.blockHashes)
  else:
    eth68.rlpxSendRequest(peer, timeout, GetBlockBodiesMsg, packet.blockHashes)

proc blockBodies*(responder: Responder;
                  bodies: openArray[BlockBody]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if responder.supports(eth70):
    eth70.rlpxSendMessage(responder, BlockBodiesMsg, bodies)
  elif responder.supports(eth69):
    eth69.rlpxSendMessage(responder, BlockBodiesMsg, bodies)
  else:
    eth68.rlpxSendMessage(responder, BlockBodiesMsg, bodies)

proc newPooledTransactionHashes*(peer: Peer; txTypes: seq[byte];
                                 txSizes: openArray[uint64];
                                 txHashes: openArray[Hash32]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if peer.supports(eth70):
    eth70.rlpxSendMessage(peer, NewPooledTransactionHashesMsg,
      txTypes, txSizes, txHashes)
  elif peer.supports(eth69):
    eth69.rlpxSendMessage(peer, NewPooledTransactionHashesMsg,
      txTypes, txSizes, txHashes)
  else:
    eth68.rlpxSendMessage(peer, NewPooledTransactionHashesMsg,
      txTypes, txSizes, txHashes)

proc getPooledTransactions*(peer: Peer; packet: PooledTransactionsRequest;
                            timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[PooledTransactionsPacket]] {.async: (
    raises: [CancelledError, EthP2PError], raw: true).} =
  if peer.supports(eth70):
    eth70.rlpxSendRequest(peer, timeout, GetPooledTransactionsMsg, packet.txHashes)
  elif peer.supports(eth69):
    eth69.rlpxSendRequest(peer, timeout, GetPooledTransactionsMsg, packet.txHashes)
  else:
    eth68.rlpxSendRequest(peer, timeout, GetPooledTransactionsMsg, packet.txHashes)

proc pooledTransactions*(responder: Responder;
                         transactions: openArray[PooledTransaction]): Future[
    void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if responder.supports(eth70):
    eth70.rlpxSendMessage(responder, PooledTransactionsMsg, transactions)
  elif responder.supports(eth69):
    eth69.rlpxSendMessage(responder, PooledTransactionsMsg, transactions)
  else:
    eth68.rlpxSendMessage(responder, PooledTransactionsMsg, transactions)

proc getReceipts*(peer: Peer; packet: ReceiptsRequest;
                  timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[ReceiptsPacket]] {.async: (raises: [CancelledError, EthP2PError],
                                   raw: true).} =
  if peer.supports(eth69):
    eth69.rlpxSendRequest(peer, timeout, GetReceiptsMsg, packet.blockHashes)
  else:
    eth68.rlpxSendRequest(peer, timeout, GetReceiptsMsg, packet.blockHashes)

proc getReceipts*(peer: Peer; firstBlockReceiptIndex: uint64; packet: ReceiptsRequest;
                  timeout: Duration = milliseconds(10000'i64)): Future[
    Opt[StoredReceipts70Packet]] {.async: (raises: [CancelledError, EthP2PError],
                                   raw: true).} =
  doAssert(peer.supports(eth70), "'getReceipts' function with 'firstBlockReceiptIndex' param only available for eth/70")
  eth70.rlpxSendRequest(peer, timeout, GetReceiptsMsg, firstBlockReceiptIndex, packet.blockHashes)

proc receipts*(responder: Responder;
               receipts: openArray[seq[Receipt]]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  doAssert(responder.supports(eth68), "'receipts' function with 'Receipt' param only available for eth/68")
  eth68.rlpxSendMessage(responder, ReceiptsMsg, receipts)

proc receipts*(responder: Responder;
               receipts: openArray[seq[StoredReceipt]]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  doAssert(responder.supports(eth69), "'receipts' function with 'StoredReceipt' param only available for eth/69")
  eth69.rlpxSendMessage(responder, ReceiptsMsg, receipts)

proc receipts*(responder: Responder; lastBlockIncomplete: bool;
               receipts: openArray[seq[StoredReceipt]]): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  doAssert(responder.supports(eth70), "'receipts' function with 'lastBlockIncomplete' and 'StoredReceipt' param only available for eth/70")
  eth70.rlpxSendMessage(responder, ReceiptsMsg, lastBlockIncomplete, receipts)

proc blockRangeUpdate*(peer: Peer; packet: BlockRangeUpdatePacket): Future[void] {.
    async: (raises: [CancelledError, EthP2PError], raw: true).} =
  if peer.supports(eth70):
    return eth70.rlpxSendMessage(peer, BlockRangeUpdateMsg,
      packet.earliest, packet.latest, packet.latestHash)
  elif peer.supports(eth69):
    return eth69.rlpxSendMessage(peer, BlockRangeUpdateMsg,
      packet.earliest, packet.latest, packet.latestHash)
  else:
    doAssert(false, "'blockRangeUpdate' function only available for eth/69 or later")

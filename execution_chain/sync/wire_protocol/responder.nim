# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  stint,
  chronicles,
  stew/byteutils,
  ./handler,
  ./requester,
  ./trace_config,
  ../../utils/utils,
  ../../common/logging,
  ../../networking/p2p_protocol_dsl,
  ../../networking/p2p_types

export
  requester

logScope:
  topics = "eth68/69"

const
  prettyEthProtoName* = "[eth/68/69]"

  # Pickeled tracer texts
  trEthRecvReceived* =
    "<< " & prettyEthProtoName & " Received "
  trEthRecvReceivedBlockHeaders* =
    trEthRecvReceived & "BlockHeaders (0x04)"
  trEthRecvReceivedBlockBodies* =
    trEthRecvReceived & "BlockBodies (0x06)"

  trEthRecvProtocolViolation* =
    "<< " & prettyEthProtoName & " Protocol violation, "
  trEthRecvError* =
    "<< " & prettyEthProtoName & " Error "
  trEthRecvTimeoutWaiting* =
    "<< " & prettyEthProtoName & " Timeout waiting "
  trEthRecvDiscarding* =
    "<< " & prettyEthProtoName & " Discarding "

  trEthSendSending* =
    ">> " & prettyEthProtoName & " Sending "
  trEthSendSendingGetBlockHeaders* =
    trEthSendSending & "GetBlockHeaders (0x03)"
  trEthSendSendingGetBlockBodies* =
    trEthSendSending & "GetBlockBodies (0x05)"

  trEthSendReplying* =
    ">> " & prettyEthProtoName & " Replying "

  trEthSendDelaying* =
    ">> " & prettyEthProtoName & " Delaying "

  trEthRecvNewBlock* =
    "<< " & prettyEthProtoName & " Received NewBlock"
  trEthRecvNewBlockHashes* =
    "<< " & prettyEthProtoName & " Received NewBlockHashes"
  trEthSendNewBlock* =
    ">> " & prettyEthProtoName & " Sending NewBlock"
  trEthSendNewBlockHashes* =
    ">> " & prettyEthProtoName & " Sending NewBlockHashes"

proc status68UserHandler(peer: Peer; packet: Status68Packet) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  trace trEthRecvReceived & "Status (0x00)", peer,
    networkId = packet.networkId,
    totalDifficulty = packet.totalDifficulty,
    bestHash = packet.bestHash.short,
    genesisHash = packet.genesisHash.short,
    forkHash = packet.forkId.forkHash.toHex,
    forkNext = packet.forkId.forkNext

proc status68Thunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketHandler(Status68Packet, peer, data,
                               [ethVersion, networkId,
                                totalDifficulty, bestHash,
                                genesisHash, forkId]):
    await status68UserHandler(peer, packet)


proc newBlockHashesUserHandler(peer: Peer; packet: NewBlockHashesPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  when trEthTraceGossipOk:
    trace trEthRecvReceived & "NewBlockHashes (0x01)", peer, hashes = packet.hashes.len
  raise newException(EthP2PError, "block broadcasts disallowed")

proc newBlockHashesThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketHandler(NewBlockHashesPacket, peer, data, [hashes]):
    await newBlockHashesUserHandler(peer, packet)


proc transactionsUserHandler(peer: Peer; packet: TransactionsPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  when trEthTraceGossipOk:
    trace trEthRecvReceived & "Transactions (0x02)", peer,
          transactions = packet.transactions.len
  let ctx = peer.networkState(eth68)
  ctx.handleAnnouncedTxs(packet)

proc transactionsThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketHandler(TransactionsPacket, peer, data, [transactions]):
    await transactionsUserHandler(peer, packet)


proc getBlockHeadersUserHandler(response: Responder;
                                request: BlockHeadersRequest) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  let peer = response.peer
  when trEthTracePacketsOk:
    trace trEthRecvReceived & "GetBlockHeaders (0x03)", peer,
          count = request.maxResults
  let ctx = peer.networkState(eth68)
  let headers = ctx.getBlockHeaders(request)
  if headers.len > 0:
    trace trEthSendReplying & "with BlockHeaders (0x04)", peer,
          sent = headers.len, requested = request.maxResults
  else:
    trace trEthSendReplying & "EMPTY BlockHeaders (0x04)", peer, sent = 0,
          requested = request.maxResults
  await response.blockHeaders(headers)

proc getBlockHeadersThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketResponder(BlockHeadersRequest, peer, data):
    await getBlockHeadersUserHandler(response, packet)


proc blockHeadersThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithFutureHandler(BlockHeadersPacket,
    BlockHeadersMsg, peer, data, [headers])


proc blockBodiesThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithFutureHandler(BlockBodiesPacket,
    BlockBodiesMsg, peer, data, [bodies])


proc getBlockBodiesUserHandler(response: Responder; hashes: seq[Hash32]) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  let peer = response.peer
  trace trEthRecvReceived & "GetBlockBodies (0x05)", peer, hashes = hashes.len
  let ctx = peer.networkState(eth68)
  let bodies = ctx.getBlockBodies(hashes)
  if bodies.len > 0:
    trace trEthSendReplying & "with BlockBodies (0x06)", peer,
          sent = bodies.len, requested = hashes.len
  else:
    trace trEthSendReplying & "EMPTY BlockBodies (0x06)", peer, sent = 0,
          requested = hashes.len
  await response.blockBodies(bodies)

proc getBlockBodiesThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketResponder(seq[Hash32], peer, data):
    await getBlockBodiesUserHandler(response, packet)


proc newBlockUserHandler(peer: Peer; packet: NewBlockPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  when trEthTraceGossipOk:
    trace trEthRecvReceived & "NewBlock (0x07)", peer, packet.totalDifficulty,
          blockNumber = packet.blk.header.number,
          blockDifficulty = packet.blk.header.difficulty
  raise newException(EthP2PError, "block broadcasts disallowed")

proc newBlockThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketHandler(NewBlockPacket, peer, data, [blk, totalDifficulty]):
    await newBlockUserHandler(peer, packet)


proc newPooledTransactionHashesUserHandler(peer: Peer; packet: NewPooledTransactionHashesPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  when trEthTraceGossipOk:
    trace trEthRecvReceived & "NewPooledTransactionHashes (0x08)", peer,
          txTypes = packet.txTypes.toHex, txSizes = packet.txSizes.toStr,
          hashes = packet.txHashes.len

proc newPooledTransactionHashesThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketHandler(NewPooledTransactionHashesPacket,
                              peer, data, [txTypes, txSizes, txHashes]):
    await newPooledTransactionHashesUserHandler(peer, packet)


proc getPooledTransactionsUserHandler(response: Responder;
                                      txHashes: seq[Hash32]) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  let peer = response.peer
  trace trEthRecvReceived & "GetPooledTransactions (0x09)", peer,
        hashes = txHashes.len
  let ctx = peer.networkState(eth68)
  let txs = ctx.getPooledTransactions(txHashes)
  if txs.len > 0:
    trace trEthSendReplying & "with PooledTransactions (0x0a)", peer,
          sent = txs.len, requested = txHashes.len
  else:
    trace trEthSendReplying & "EMPTY PooledTransactions (0x0a)", peer, sent = 0,
          requested = txHashes.len
  await response.pooledTransactions(txs)

proc getPooledTransactionsThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketResponder(seq[Hash32], peer, data):
    await getPooledTransactionsUserHandler(response, packet)


proc pooledTransactionsThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithFutureHandler(PooledTransactionsPacket,
    PooledTransactionsMsg, peer, data, [transactions])


proc getReceiptsUserHandler(response: Responder; hashes: seq[Hash32]) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  let peer = response.peer
  trace trEthRecvReceived & "GetReceipts (0x0f)", peer, hashes = hashes.len
  let ctx = peer.networkState(eth68)
  let rec = ctx.getReceipts(hashes)
  if rec.len > 0:
    trace trEthSendReplying & "with Receipts (0x10)", peer, sent = rec.len,
          requested = hashes.len
  else:
    trace trEthSendReplying & "EMPTY Receipts (0x10)", peer, sent = 0,
          requested = hashes.len
  await response.receipts(rec)

proc getReceiptsThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithPacketResponder(seq[Hash32], peer, data):
    await getReceiptsUserHandler(response, packet)


proc receiptsThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth68.rlpxWithFutureHandler(ReceiptsPacket,
    ReceiptsMsg, peer, data, [receipts])


proc eth68PeerConnected(peer: Peer) {.async: (
    raises: [CancelledError, EthP2PError]).} =
  let
    network = peer.network
    ctx = peer.networkState(eth68)
    status = ctx.getStatus68()
    packet = Status68Packet(
      ethVersion: eth68.protocolVersion,
      networkId : network.networkId,
      totalDifficulty: status.totalDifficulty,
      bestHash: status.bestBlockHash,
      genesisHash: status.genesisHash,
      forkId: status.forkId,
    )

  trace trEthSendSending & "Status (0x00)", peer,
     td = status.totalDifficulty,
     bestHash = short(status.bestBlockHash),
     networkId = network.networkId,
     genesis = short(status.genesisHash),
     forkHash = status.forkId.forkHash.toHex,
     forkNext = status.forkId.forkNext

  let m = await peer.status68(packet, timeout = chronos.seconds(10))
  when trEthTraceHandshakesOk:
    trace "Handshake: Local and remote networkId", local = network.networkId,
          remote = m.networkId
    trace "Handshake: Local and remote genesisHash",
          local = short(status.genesisHash), remote = short(m.genesisHash)
    trace "Handshake: Local and remote forkId", local = (
        status.forkId.forkHash.toHex & "/" & $status.forkId.forkNext),
          remote = (m.forkId.forkHash.toHex & "/" & $m.forkId.forkNext)
  if m.networkId != network.networkId:
    trace "Peer for a different network (networkId)", peer,
          expectNetworkId = network.networkId, gotNetworkId = m.networkId
    raise newException(UselessPeerError, "Eth handshake for different network")
  if m.genesisHash != status.genesisHash:
    trace "Peer for a different network (genesisHash)", peer,
          expectGenesis = short(status.genesisHash),
          gotGenesis = short(m.genesisHash)
    raise newException(UselessPeerError, "Eth handshake for different network")
  trace "Peer matches our network", peer

  peer.state(eth68).initialized = true
  peer.state(eth68).bestDifficulty = m.totalDifficulty
  peer.state(eth68).bestBlockHash = m.bestHash


proc eth68Registration() =
  let
    protocol = eth68.initProtocol()

  setEventHandlers(protocol, eth68PeerConnected, nil)
  registerMsg(protocol, StatusMsg, "status",
              status68Thunk, Status68Packet)
  registerMsg(protocol, NewBlockHashesMsg, "newBlockHashes",
              newBlockHashesThunk, NewBlockHashesPacket)
  registerMsg(protocol, TransactionMsg, "transactions",
              transactionsThunk, TransactionsPacket)
  registerMsg(protocol, BlockHeadersMsg, "blockHeaders",
              blockHeadersThunk, BlockHeadersPacket)
  registerMsg(protocol, GetBlockHeadersMsg, "getBlockHeaders",
              getBlockHeadersThunk, BlockHeadersRequest)
  registerMsg(protocol, BlockBodiesMsg, "blockBodies",
              blockBodiesThunk, BlockBodiesPacket)
  registerMsg(protocol, GetBlockBodiesMsg, "getBlockBodies",
              getBlockBodiesThunk, BlockBodiesRequest)
  registerMsg(protocol, NewBlockMsg, "newBlock",
              newBlockThunk, NewBlockPacket)
  registerMsg(protocol, NewPooledTransactionHashesMsg, "newPooledTransactionHashes",
              newPooledTransactionHashesThunk, NewPooledTransactionHashesPacket)
  registerMsg(protocol, PooledTransactionsMsg, "pooledTransactions",
              pooledTransactionsThunk, PooledTransactionsPacket)
  registerMsg(protocol, GetPooledTransactionsMsg, "getPooledTransactions",
              getPooledTransactionsThunk, PooledTransactionsRequest)
  registerMsg(protocol, ReceiptsMsg, "receipts",
              receiptsThunk, ReceiptsPacket)
  registerMsg(protocol, GetReceiptsMsg, "getReceipts",
              getReceiptsThunk, ReceiptsRequest)

  registerProtocol(protocol)

eth68Registration()

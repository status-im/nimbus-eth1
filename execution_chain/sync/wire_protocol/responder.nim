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
  eth/common/transactions_rlp,
  ./types,
  ./handler,
  ./requester,
  ./broadcast,
  ./trace_config,
  ../../utils/utils,
  ../../common/logging,
  ../../core/pooled_txs_rlp,
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
                               [version, networkId,
                                totalDifficulty, bestHash,
                                genesisHash, forkId]):
    await status68UserHandler(peer, packet)

proc status69UserHandler(peer: Peer; packet: Status69Packet) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  trace trEthRecvReceived & "Status (0x00)", peer,
    networkId = packet.networkId,
    genesisHash = packet.genesisHash.short,
    forkHash = packet.forkId.forkHash.toHex,
    forkNext = packet.forkId.forkNext,
    earliest = packet.earliest,
    latest = packet.latest,
    latestHash = packet.latestHash.short

proc status69Thunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  eth69.rlpxWithPacketHandler(Status69Packet, peer, data,
                               [version, networkId,
                                genesisHash, forkId,
                                earliest, latest, latestHash]):
    await status69UserHandler(peer, packet)

proc newBlockHashesUserHandler(peer: Peer; packet: NewBlockHashesPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  when trEthTraceGossipOk:
    trace trEthRecvReceived & "NewBlockHashes (0x01)", peer, hashes = packet.hashes.len
  raise newException(EthP2PError, "block broadcasts disallowed")

proc newBlockHashesThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketHandler(NewBlockHashesPacket, peer, data, [hashes]):
    await newBlockHashesUserHandler(peer, packet)

proc transactionsUserHandler[PROTO](peer: Peer; packet: TransactionsPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  when trEthTraceGossipOk:
    trace trEthRecvReceived & "Transactions (0x02)", peer,
          transactions = packet.transactions.len
  let ctx = peer.networkState(PROTO)
  await ctx.handleTransactionsBroadcast(packet, peer)

proc transactionsThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketHandler(TransactionsPacket, peer, data, [transactions]):
    await transactionsUserHandler[PROTO](peer, packet)


proc getBlockHeadersUserHandler[PROTO](response: Responder;
                                request: BlockHeadersRequest) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  let peer = response.peer
  when trEthTracePacketsOk:
    trace trEthRecvReceived & "GetBlockHeaders (0x03)", peer,
          count = request.maxResults
  let ctx = peer.networkState(PROTO)
  let headers = ctx.getBlockHeaders(request)
  if headers.len > 0:
    trace trEthSendReplying & "with BlockHeaders (0x04)", peer,
          sent = headers.len, requested = request.maxResults
  else:
    trace trEthSendReplying & "EMPTY BlockHeaders (0x04)", peer, sent = 0,
          requested = request.maxResults
  await response.blockHeaders(headers)

proc getBlockHeadersThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketResponder(BlockHeadersRequest, peer, data):
    await getBlockHeadersUserHandler[PROTO](response, packet)


proc blockHeadersThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithFutureHandler(BlockHeadersPacket,
    BlockHeadersMsg, peer, data, [headers])


proc blockBodiesThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithFutureHandler(BlockBodiesPacket,
    BlockBodiesMsg, peer, data, [bodies])


proc getBlockBodiesUserHandler[PROTO](response: Responder; hashes: seq[Hash32]) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  let peer = response.peer
  trace trEthRecvReceived & "GetBlockBodies (0x05)", peer, hashes = hashes.len
  let ctx = peer.networkState(PROTO)
  let bodies = ctx.getBlockBodies(hashes)
  if bodies.len > 0:
    trace trEthSendReplying & "with BlockBodies (0x06)", peer,
          sent = bodies.len, requested = hashes.len
  else:
    trace trEthSendReplying & "EMPTY BlockBodies (0x06)", peer, sent = 0,
          requested = hashes.len
  await response.blockBodies(bodies)

proc getBlockBodiesThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketResponder(seq[Hash32], peer, data):
    await getBlockBodiesUserHandler[PROTO](response, packet)


proc newBlockUserHandler(peer: Peer; packet: NewBlockPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  when trEthTraceGossipOk:
    trace trEthRecvReceived & "NewBlock (0x07)", peer, packet.totalDifficulty,
          blockNumber = packet.blk.header.number,
          blockDifficulty = packet.blk.header.difficulty
  raise newException(EthP2PError, "block broadcasts disallowed")

proc newBlockThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketHandler(NewBlockPacket, peer, data, [blk, totalDifficulty]):
    await newBlockUserHandler(peer, packet)


proc newPooledTransactionHashesUserHandler(peer: Peer;
      wire: EthWireRef;
      packet: NewPooledTransactionHashesPacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  when trEthTraceGossipOk:
    trace trEthRecvReceived & "NewPooledTransactionHashes (0x08)", peer,
          txTypes = packet.txTypes.toHex, txSizes = packet.txSizes.toStr,
          hashes = packet.txHashes.len
  await wire.handleTxHashesBroadcast(packet, peer)

proc newPooledTransactionHashesThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketHandler(NewPooledTransactionHashesPacket,
                              peer, data, [txTypes, txSizes, txHashes]):
    let wire = peer.networkState(PROTO)
    await newPooledTransactionHashesUserHandler(peer, wire, packet)


proc getPooledTransactionsUserHandler[PROTO](response: Responder;
                                      txHashes: seq[Hash32]) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  let peer = response.peer
  trace trEthRecvReceived & "GetPooledTransactions (0x09)", peer,
        hashes = txHashes.len
  let ctx = peer.networkState(PROTO)
  let txs = ctx.getPooledTransactions(txHashes)
  if txs.len > 0:
    trace trEthSendReplying & "with PooledTransactions (0x0a)", peer,
          sent = txs.len, requested = txHashes.len
  else:
    trace trEthSendReplying & "EMPTY PooledTransactions (0x0a)", peer, sent = 0,
          requested = txHashes.len
  await response.pooledTransactions(txs)

proc getPooledTransactionsThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketResponder(seq[Hash32], peer, data):
    await getPooledTransactionsUserHandler[PROTO](response, packet)


proc pooledTransactionsThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithFutureHandler(PooledTransactionsPacket,
    PooledTransactionsMsg, peer, data, [transactions])


proc getReceiptsUserHandler[PROTO](response: Responder; hashes: seq[Hash32]) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  let peer = response.peer
  trace trEthRecvReceived & "GetReceipts (0x0f)", peer, hashes = hashes.len
  let ctx = peer.networkState(PROTO)
  let rec = when PROTO is eth69:
              ctx.getStoredReceipts(hashes)
            else:
              ctx.getReceipts(hashes)
  if rec.len > 0:
    trace trEthSendReplying & "with Receipts (0x10)", peer, sent = rec.len,
          requested = hashes.len
  else:
    trace trEthSendReplying & "EMPTY Receipts (0x10)", peer, sent = 0,
          requested = hashes.len
  await response.receipts(rec)

proc getReceiptsThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketResponder(seq[Hash32], peer, data):
    await getReceiptsUserHandler[PROTO](response, packet)

proc receiptsThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  when PROTO is eth69:
    PROTO.rlpxWithFutureHandler(StoredReceiptsPacket, ReceiptsPacket,
      ReceiptsMsg, peer, data, [receipts])
  else:
    PROTO.rlpxWithFutureHandler(ReceiptsPacket,
      ReceiptsMsg, peer, data, [receipts])

proc blockRangeUpdateUserHandler(peer: Peer; packet: BlockRangeUpdatePacket) {.
    async: (raises: [CancelledError, EthP2PError]).} =

  when trEthTraceGossipOk:
    trace trEthRecvReceived & "BlockRangeUpdate (0x11)", peer,
      earliest = packet.earliest, latest = packet.latest,
      latestHash = packet.latestHash.short

  if packet.earliest > packet.latest:
    debug "Disconnecting peer because of protocol breach",
      remote = peer.remote, clientId = peer.clientId,
      msg = "blockRangeUpdate must have latest >= earliest"
    await peer.disconnect(BreachOfProtocol)
    return

  peer.state(eth69).earliest = packet.earliest
  peer.state(eth69).latest = packet.latest
  peer.state(eth69).latestHash = packet.latestHash

proc blockRangeUpdateThunk[PROTO](peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  PROTO.rlpxWithPacketHandler(BlockRangeUpdatePacket,
                              peer, data, [earliest, latest, latestHash]):
    await blockRangeUpdateUserHandler(peer, packet)


proc eth68PeerConnected(peer: Peer) {.async: (
    raises: [CancelledError, EthP2PError]).} =
  let
    network = peer.network
    ctx = peer.networkState(eth68)
    status = ctx.getStatus68()
    packet = Status68Packet(
      version: eth68.protocolVersion,
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

proc eth69PeerConnected(peer: Peer) {.async: (
    raises: [CancelledError, EthP2PError]).} =
  let
    network = peer.network
    ctx = peer.networkState(eth69)
    status = ctx.getStatus69()
    packet = Status69Packet(
      version: eth69.protocolVersion,
      networkId : network.networkId,
      genesisHash: status.genesisHash,
      forkId: status.forkId,
      earliest: status.earliest,
      latest: status.latest,
      latestHash: status.latestHash,
    )

  trace trEthSendSending & "Status (0x00)", peer,
     earliest = status.earliest,
     latest = status.latest,
     latestHash = status.latestHash.short,
     networkId = network.networkId,
     genesis = short(status.genesisHash),
     forkHash = status.forkId.forkHash.toHex,
     forkNext = status.forkId.forkNext

  let m = await peer.status69(packet, timeout = chronos.seconds(10))
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

  peer.state(eth69).initialized = true
  peer.state(eth69).earliest = m.earliest
  peer.state(eth69).latest = m.latest
  peer.state(eth69).latestHash = m.latestHash

template registerCommonThunk(protocol: ProtocolInfo, PROTO: type) =
  registerMsg(protocol, NewBlockHashesMsg, "newBlockHashes",
              newBlockHashesThunk[PROTO], NewBlockHashesPacket)
  registerMsg(protocol, TransactionMsg, "transactions",
              transactionsThunk[PROTO], TransactionsPacket)
  registerMsg(protocol, BlockHeadersMsg, "blockHeaders",
              blockHeadersThunk[PROTO], BlockHeadersPacket)
  registerMsg(protocol, GetBlockHeadersMsg, "getBlockHeaders",
              getBlockHeadersThunk[PROTO], BlockHeadersRequest)
  registerMsg(protocol, BlockBodiesMsg, "blockBodies",
              blockBodiesThunk[PROTO], BlockBodiesPacket)
  registerMsg(protocol, GetBlockBodiesMsg, "getBlockBodies",
              getBlockBodiesThunk[PROTO], BlockBodiesRequest)
  registerMsg(protocol, NewBlockMsg, "newBlock",
              newBlockThunk[PROTO], NewBlockPacket)
  registerMsg(protocol, NewPooledTransactionHashesMsg, "newPooledTransactionHashes",
              newPooledTransactionHashesThunk[PROTO], NewPooledTransactionHashesPacket)
  registerMsg(protocol, PooledTransactionsMsg, "pooledTransactions",
              pooledTransactionsThunk[PROTO], PooledTransactionsPacket)
  registerMsg(protocol, GetPooledTransactionsMsg, "getPooledTransactions",
              getPooledTransactionsThunk[PROTO], PooledTransactionsRequest)
  registerMsg(protocol, ReceiptsMsg, "receipts",
              receiptsThunk[PROTO], ReceiptsPacket)
  registerMsg(protocol, GetReceiptsMsg, "getReceipts",
              getReceiptsThunk[PROTO], ReceiptsRequest)

proc eth68Registration() =
  let
    protocol = eth68.initProtocol()

  setEventHandlers(protocol, eth68PeerConnected, nil)
  registerMsg(protocol, StatusMsg, "status",
              status68Thunk, Status68Packet)
  registerCommonThunk(protocol, eth68)
  registerProtocol(protocol)

proc eth69Registration() =
  let
    protocol = eth69.initProtocol()

  setEventHandlers(protocol, eth69PeerConnected, nil)
  registerMsg(protocol, StatusMsg, "status",
              status69Thunk, Status69Packet)
  registerCommonThunk(protocol, eth69)
  registerMsg(protocol, BlockRangeUpdateMsg, "blockRangeUpdate",
              blockRangeUpdateThunk[eth69], BlockRangeUpdatePacket)
  registerProtocol(protocol)

eth68Registration()
eth69Registration()

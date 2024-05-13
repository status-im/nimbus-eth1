# Nimbus - Ethereum Wire Protocol
#
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module implements Ethereum Wire Protocol version 67, `eth/67`.
## Specification:
##   `eth/68 <https://github.com/ethereum/devp2p/blob/master/caps/eth.md>`_

import
  stint,
  chronicles,
  chronos,
  eth/[common, p2p, p2p/private/p2p_types],
  stew/byteutils,
  ./trace_config,
  ./eth/eth_types,
  ../types,
  ../../utils/utils

export
  eth_types

logScope:
  topics = "eth68"

const
  ethVersion* = 68
  prettyEthProtoName* = "[eth/" & $ethVersion & "]"

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

template handleHandlerError(x: untyped) =
  if x.isErr:
    raise newException(EthP2PError, x.error)

p2pProtocol eth68(version = ethVersion,
                  rlpxName = "eth",
                  peerState = EthPeerState,
                  networkState = EthWireBase,
                  useRequestIds = true):

  onPeerConnected do (peer: Peer):
    let
      network   = peer.network
      ctx       = peer.networkState
      statusRes = ctx.getStatus()

    handleHandlerError(statusRes)
    let status = statusRes.get

    trace trEthSendSending & "Status (0x00)", peer,
      td        = status.totalDifficulty,
      bestHash  = short(status.bestBlockHash),
      networkId = network.networkId,
      genesis   = short(status.genesisHash),
      forkHash  = status.forkId.forkHash.toHex,
      forkNext  = status.forkId.forkNext

    let m = await peer.status(ethVersion,
                              network.networkId,
                              status.totalDifficulty,
                              status.bestBlockHash,
                              status.genesisHash,
                              status.forkId,
                              timeout = chronos.seconds(10))

    when trEthTraceHandshakesOk:
      trace "Handshake: Local and remote networkId",
        local=network.networkId, remote=m.networkId
      trace "Handshake: Local and remote genesisHash",
        local=short(status.genesisHash), remote=short(m.genesisHash)
      trace "Handshake: Local and remote forkId",
        local=(status.forkId.forkHash.toHex & "/" & $status.forkId.forkNext),
        remote=(m.forkId.forkHash.toHex & "/" & $m.forkId.forkNext)

    if m.networkId != network.networkId:
      trace "Peer for a different network (networkId)", peer,
        expectNetworkId=network.networkId, gotNetworkId=m.networkId
      raise newException(
        UselessPeerError, "Eth handshake for different network")

    if m.genesisHash != status.genesisHash:
      trace "Peer for a different network (genesisHash)", peer,
        expectGenesis=short(status.genesisHash), gotGenesis=short(m.genesisHash)
      raise newException(
        UselessPeerError, "Eth handshake for different network")

    trace "Peer matches our network", peer
    peer.state.initialized = true
    peer.state.bestDifficulty = m.totalDifficulty
    peer.state.bestBlockHash = m.bestHash

  handshake:
    # User message 0x00: Status.
    proc status(peer: Peer,
                ethVersionArg: uint,
                networkId: NetworkId,
                totalDifficulty: DifficultyInt,
                bestHash: Hash256,
                genesisHash: Hash256,
                forkId: ChainForkId) =
      trace trEthRecvReceived & "Status (0x00)", peer,
          networkId, totalDifficulty, bestHash=short(bestHash), genesisHash=short(genesisHash),
         forkHash=forkId.forkHash.toHex, forkNext=forkId.forkNext

  # User message 0x01: NewBlockHashes.
  proc newBlockHashes(peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) =
    when trEthTraceGossipOk:
      trace trEthRecvReceived & "NewBlockHashes (0x01)", peer,
        hashes=hashes.len

    let ctx = peer.networkState()
    let res = ctx.handleNewBlockHashes(peer, hashes)
    handleHandlerError(res)

  # User message 0x02: Transactions.
  proc transactions(peer: Peer, transactions: openArray[Transaction]) =
    when trEthTraceGossipOk:
      trace trEthRecvReceived & "Transactions (0x02)", peer,
        transactions=transactions.len

    let ctx = peer.networkState()
    let res = ctx.handleAnnouncedTxs(peer, transactions)
    handleHandlerError(res)

  requestResponse:
    # User message 0x03: GetBlockHeaders.
    proc getBlockHeaders(peer: Peer, request: BlocksRequest) =
      when trEthTracePacketsOk:
        trace trEthRecvReceived & "GetBlockHeaders (0x03)", peer,
          count=request.maxResults

      if request.maxResults > uint64(maxHeadersFetch):
        debug "GetBlockHeaders (0x03) requested too many headers",
          peer, requested=request.maxResults, max=maxHeadersFetch
        await peer.disconnect(BreachOfProtocol)
        return

      let ctx = peer.networkState()
      let headers = ctx.getBlockHeaders(request)
      handleHandlerError(headers)
      if headers.get.len > 0:
        trace trEthSendReplying & "with BlockHeaders (0x04)", peer,
          sent=headers.get.len, requested=request.maxResults
      else:
        trace trEthSendReplying & "EMPTY BlockHeaders (0x04)", peer,
          sent=0, requested=request.maxResults

      await response.send(headers.get)

    # User message 0x04: BlockHeaders.
    proc blockHeaders(p: Peer, headers: openArray[BlockHeader])

  requestResponse:
    # User message 0x05: GetBlockBodies.
    proc getBlockBodies(peer: Peer, hashes: openArray[Hash256]) =
      trace trEthRecvReceived & "GetBlockBodies (0x05)", peer,
        hashes=hashes.len
      if hashes.len > maxBodiesFetch:
        debug "GetBlockBodies (0x05) requested too many bodies",
          peer, requested=hashes.len, max=maxBodiesFetch
        await peer.disconnect(BreachOfProtocol)
        return

      let ctx = peer.networkState()
      let bodies = ctx.getBlockBodies(hashes)
      handleHandlerError(bodies)
      if bodies.get.len > 0:
        trace trEthSendReplying & "with BlockBodies (0x06)", peer,
          sent=bodies.get.len, requested=hashes.len
      else:
        trace trEthSendReplying & "EMPTY BlockBodies (0x06)", peer,
          sent=0, requested=hashes.len

      await response.send(bodies.get)

    # User message 0x06: BlockBodies.
    proc blockBodies(peer: Peer, blocks: openArray[BlockBody])

  # User message 0x07: NewBlock.
  proc newBlock(peer: Peer, blk: EthBlock, totalDifficulty: DifficultyInt) =
    # (Note, needs to use `EthBlock` instead of its alias `NewBlockAnnounce`
    # because either `p2pProtocol` or RLPx doesn't work with an alias.)
    when trEthTraceGossipOk:
      trace trEthRecvReceived & "NewBlock (0x07)", peer,
        totalDifficulty,
        blockNumber = blk.header.blockNumber,
        blockDifficulty = blk.header.difficulty

    let ctx = peer.networkState()
    let res = ctx.handleNewBlock(peer, blk, totalDifficulty)
    handleHandlerError(res)

  # User message 0x08: NewPooledTransactionHashes.
  proc newPooledTransactionHashes(
      peer: Peer,
      txTypes: Blob,
      txSizes: openArray[int],
      txHashes: openArray[Hash256]
        ) =
    when trEthTraceGossipOk:
      trace trEthRecvReceived & "NewPooledTransactionHashes (0x08)", peer,
        txTypes=txTypes.toHex, txSizes,
        hashes=txHashes.len

    let ctx = peer.networkState()
    let res = ctx.handleAnnouncedTxsHashes(peer, txTypes, txSizes, txHashes)
    handleHandlerError(res)

  requestResponse:
    # User message 0x09: GetPooledTransactions.
    proc getPooledTransactions(peer: Peer, txHashes: openArray[Hash256]) =
      trace trEthRecvReceived & "GetPooledTransactions (0x09)", peer,
        hashes=txHashes.len

      let ctx = peer.networkState()
      let txs = ctx.getPooledTxs(txHashes)
      handleHandlerError(txs)
      if txs.get.len > 0:
        trace trEthSendReplying & "with PooledTransactions (0x0a)", peer,
          sent=txs.get.len, requested=txHashes.len
      else:
        trace trEthSendReplying & "EMPTY PooledTransactions (0x0a)", peer,
          sent=0, requested=txHashes.len

      await response.send(txs.get)

    # User message 0x0a: PooledTransactions.
    proc pooledTransactions(
        peer: Peer, transactions: openArray[PooledTransaction])

  # User message 0x0d: GetNodeData -- removed, was so 66ish
  # User message 0x0e: NodeData -- removed, was so 66ish

  nextId 0x0f

  requestResponse:
    # User message 0x0f: GetReceipts.
    proc getReceipts(peer: Peer, hashes: openArray[Hash256]) =
      trace trEthRecvReceived & "GetReceipts (0x0f)", peer,
        hashes=hashes.len

      let ctx = peer.networkState()
      let rec = ctx.getReceipts(hashes)
      handleHandlerError(rec)
      if rec.get.len > 0:
        trace trEthSendReplying & "with Receipts (0x10)", peer,
          sent=rec.get.len, requested=hashes.len
      else:
        trace trEthSendReplying & "EMPTY Receipts (0x10)", peer,
          sent=0, requested=hashes.len

      await response.send(rec.get)

    # User message 0x10: Receipts.
    proc receipts(peer: Peer, receipts: openArray[seq[Receipt]])

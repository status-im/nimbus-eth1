# Nimbus - Ethereum Wire Protocol, version eth/65
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module implements Ethereum Wire Protocol version 66, `eth/66`.
## Specification:
##   `eth/66 <https://github.com/ethereum/devp2p/blob/master/caps/eth.md>`_

import
  chronos, stint, chronicles, stew/byteutils, macros,
  eth/[common/eth_types, rlp, p2p],
  eth/p2p/[rlpx, private/p2p_types, blockchain_utils],
  ".."/[sync_types, trace_helper],
  ./pickeled_eth_tracers

export
  tracePackets, tracePacket,
  traceGossips, traceGossip,
  traceTimeouts, traceTimeout,
  traceNetworkErrors, traceNetworkError,
  tracePacketErrors, tracePacketError

type
  NewBlockHashesAnnounce* = object
    hash: BlockHash
    number: BlockNumber

  NewBlockAnnounce* = EthBlock

  ForkId* = object
    forkHash: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext: BlockNumber    # The RLP encoding must be variable-length

  PeerState = ref object
    initialized*: bool
    bestBlockHash*: BlockHash
    bestDifficulty*: DifficultyInt

    onGetNodeData*:
      proc (peer: Peer, hashes: openArray[NodeHash],
            data: var seq[Blob]) {.gcsafe.}
    onNodeData*:
      proc (peer: Peer, data: openArray[Blob]) {.gcsafe.}

const
  maxStateFetch* = 384
  maxBodiesFetch* = 128
  maxReceiptsFetch* = 256
  maxHeadersFetch* = 192
  ethVersion* = 66
  prettyEthProtoName* = "[eth/" & $ethVersion & "]"


p2pProtocol eth66(version = ethVersion,
                  rlpxName = "eth",
                  peerState = PeerState,
                  useRequestIds = true):

  onPeerConnected do (peer: Peer):
    let
      network = peer.network
      chain = network.chain
      bestBlock = chain.getBestBlockHeader
      chainForkId = chain.getForkId(bestBlock.blockNumber)
      forkId = ForkId(
        forkHash: chainForkId.crc.toBytesBE,
        forkNext: chainForkId.nextFork.toBlockNumber)

    traceSending "Status (0x00) " & prettyEthProtoName,
      peer, td=bestBlock.difficulty,
      bestHash=bestBlock.blockHash.toHex,
      networkId=network.networkId,
      genesis=chain.genesisHash.toHex,
      forkHash=forkId.forkHash.toHex, forkNext=forkId.forkNext

    let m = await peer.status(ethVersion,
                              network.networkId,
                              bestBlock.difficulty,
                              bestBlock.blockHash,
                              chain.genesisHash,
                              forkId,
                              timeout = chronos.seconds(10))

    if traceHandshakes:
      trace "Handshake: Local and remote networkId",
        local=network.networkId, remote=m.networkId
      trace "Handshake: Local and remote genesisHash",
        local=chain.genesisHash.toHex, remote=m.genesisHash.toHex
      trace "Handshake: Local and remote forkId",
        local=(forkId.forkHash.toHex & "/" & $forkId.forkNext),
        remote=(m.forkId.forkHash.toHex & "/" & $m.forkId.forkNext)

    if m.networkId != network.networkId:
      trace "Peer for a different network (networkId)", peer,
        expectNetworkId=network.networkId, gotNetworkId=m.networkId
      raise newException(UselessPeerError, "Eth handshake for different network")

    if m.genesisHash != chain.genesisHash:
      trace "Peer for a different network (genesisHash)", peer,
        expectGenesis=chain.genesisHash.toHex, gotGenesis=m.genesisHash.toHex
      raise newException(UselessPeerError, "Eth handshake for different network")

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
                bestHash: BlockHash,
                genesisHash: BlockHash,
                forkId: ForkId) =
      traceReceived "Status (0x00)",
         peer, td=totalDifficulty,
         bestHash=bestHash.toHex,
         networkId,
         genesis=genesisHash.toHex,
         forkHash=forkId.forkHash.toHex, forkNext=forkId.forkNext

  # User message 0x01: NewBlockHashes.
  proc newBlockHashes(peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) =
    traceGossipDiscarding "NewBlockHashes (0x01)",
      peer, hashes=hashes.len
    discard

  # User message 0x02: Transactions.
  proc transactions(peer: Peer, transactions: openArray[Transaction]) =
    traceGossipDiscarding "Transactions (0x02)",
      peer, transactions=transactions.len
    discard

  requestResponse:
    # User message 0x03: GetBlockHeaders.
    proc getBlockHeaders(peer: Peer, request: BlocksRequest) =
      if tracePackets:
        if request.maxResults == 1 and request.startBlock.isHash:
          traceReceived "GetBlockHeaders/Hash (0x03)",
            peer, blockHash=($request.startBlock.hash), count=1
        elif request.maxResults == 1:
          traceReceived "GetBlockHeaders (0x03)",
            peer, `block`=request.startBlock.number, count=1
        elif request.startBlock.isHash:
          traceReceived "GetBlockHeaders/Hash (0x03)",
            peer, firstBlockHash=($request.startBlock.hash),
            count=request.maxResults,
            step=traceStep(request)
        else:
          traceReceived "GetBlockHeaders (0x03)",
            peer, firstBlock=request.startBlock.number,
            count=request.maxResults,
            step=traceStep(request)

      if request.maxResults > uint64(maxHeadersFetch):
        debug "GetBlockHeaders (0x03) requested too many headers",
          peer, requested=request.maxResults, max=maxHeadersFetch
        await peer.disconnect(BreachOfProtocol)
        return

      let headers = peer.network.chain.getBlockHeaders(request)
      if headers.len > 0:
        traceReplying "with BlockHeaders (0x04)",
          peer, sent=headers.len, requested=request.maxResults
      else:
        traceReplying "EMPTY BlockHeaders (0x04)",
          peer, sent=0, requested=request.maxResults

      await response.send(headers)

    # User message 0x04: BlockHeaders.
    proc blockHeaders(p: Peer, headers: openArray[BlockHeader])

  requestResponse:
    # User message 0x05: GetBlockBodies.
    proc getBlockBodies(peer: Peer, hashes: openArray[BlockHash]) =
      traceReceived "GetBlockBodies (0x05)",
        peer, hashes=hashes.len
      if hashes.len > maxBodiesFetch:
        debug "GetBlockBodies (0x05) requested too many bodies",
          peer, requested=hashes.len, max=maxBodiesFetch
        await peer.disconnect(BreachOfProtocol)
        return

      let bodies = peer.network.chain.getBlockBodies(hashes)
      if bodies.len > 0:
        traceReplying "with BlockBodies (0x06)",
          peer, sent=bodies.len, requested=hashes.len
      else:
        traceReplying "EMPTY BlockBodies (0x06)",
          peer, sent=0, requested=hashes.len

      await response.send(bodies)

    # User message 0x06: BlockBodies.
    proc blockBodies(peer: Peer, blocks: openArray[BlockBody])

  # User message 0x07: NewBlock.
  proc newBlock(peer: Peer, bh: EthBlock, totalDifficulty: DifficultyInt) =
    # (Note, needs to use `EthBlock` instead of its alias `NewBlockAnnounce`
    # because either `p2pProtocol` or RLPx doesn't work with an alias.)
    traceGossipDiscarding "NewBlock (0x07)",
      peer, totalDifficulty,
      blockNumber = bh.header.blockNumber,
      blockDifficulty = bh.header.difficulty
    discard

  # User message 0x08: NewPooledTransactionHashes.
  proc newPooledTransactionHashes(peer: Peer, hashes: openArray[TxHash]) =
    traceGossipDiscarding "NewPooledTransactionHashes (0x08)",
      peer, hashes=hashes.len
    discard

  requestResponse:
    # User message 0x09: GetPooledTransactions.
    proc getPooledTransactions(peer: Peer, hashes: openArray[TxHash]) =
      traceReceived "GetPooledTransactions (0x09)",
         peer, hashes=hashes.len

      traceReplying "EMPTY PooledTransactions (0x10)",
         peer, sent=0, requested=hashes.len
      await response.send([])

    # User message 0x0a: PooledTransactions.
    proc pooledTransactions(peer: Peer, transactions: openArray[Transaction])

  nextId 0x0d

  # User message 0x0d: GetNodeData.
  proc getNodeData(peer: Peer, hashes: openArray[NodeHash]) =
    traceReceived "GetNodeData (0x0d)", peer,
      hashes=hashes.len

    var data: seq[Blob]
    if not peer.state.onGetNodeData.isNil:
      peer.state.onGetNodeData(peer, hashes, data)
    else:
      data = peer.network.chain.getStorageNodes(hashes)

    if data.len > 0:
      traceReplying "with NodeData (0x0e)", peer,
        sent=data.len, requested=hashes.len
    else:
      traceReplying "EMPTY NodeData (0x0e)", peer,
        sent=0, requested=hashes.len

    await peer.nodeData(data)

  # User message 0x0e: NodeData.
  proc nodeData(peer: Peer, data: openArray[Blob]) =
    if not peer.state.onNodeData.isNil:
      # The `onNodeData` should do its own `tracePacket`, because we don't
      # know if this is a valid reply ("Got reply") or something else.
      peer.state.onNodeData(peer, data)
    else:
      traceDiscarding "NodeData (0x0e)", peer,
        bytes=data.len

  requestResponse:
    # User message 0x0f: GetReceipts.
    proc getReceipts(peer: Peer, hashes: openArray[BlockHash]) =
      traceReceived "GetReceipts (0x0f)",
        peer, hashes=hashes.len

      traceReplying "EMPTY Receipts (0x10)",
         peer, sent=0, requested=hashes.len
      await response.send([])
      # TODO: implement `getReceipts` and reactivate this code
      # await response.send(peer.network.chain.getReceipts(hashes))

    # User message 0x10: Receipts.
    proc receipts(peer: Peer, receipts: openArray[Receipt])

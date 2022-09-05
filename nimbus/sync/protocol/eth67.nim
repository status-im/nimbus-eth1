# Nimbus - Ethereum Wire Protocol
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module implements Ethereum Wire Protocol version 67, `eth/67`.
## Specification:
##   `eth/67 <https://github.com/ethereum/devp2p/blob/master/caps/eth.md>`_

import
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, p2p/private/p2p_types, p2p/blockchain_utils],
  stew/byteutils,
  ./trace_config

logScope:
  topics = "datax"

type
  NewBlockHashesAnnounce* = object
    hash: Hash256
    number: BlockNumber

  NewBlockAnnounce* = EthBlock

  ForkId* = object
    forkHash: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext: BlockNumber    # The RLP encoding must be variable-length

  PeerState = ref object
    initialized*: bool
    bestBlockHash*: Hash256
    bestDifficulty*: DifficultyInt

const
  maxStateFetch* = 384
  maxBodiesFetch* = 128
  maxReceiptsFetch* = 256
  maxHeadersFetch* = 192
  ethVersion* = 67
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

func toHex(hash: Hash256): string =
  ## Shortcut for `byteutils.toHex(hash.data)`
  hash.data.toHex

p2pProtocol eth67(version = ethVersion,
                  rlpxName = "eth",
                  peerState = PeerState,
                  useRequestIds = true):

  onPeerConnected do (peer: Peer):
    let
      network = peer.network
      chain = network.chain
      bestBlock = chain.getBestBlockHeader
      totalDifficulty = chain.getTotalDifficulty
      chainForkId = chain.getForkId(bestBlock.blockNumber)
      forkId = ForkId(
        forkHash: chainForkId.crc.toBytesBE,
        forkNext: chainForkId.nextFork.toBlockNumber)

    trace trEthSendSending & "Status (0x00)", peer,
      td=totalDifficulty,
      bestHash=bestBlock.blockHash.toHex,
      networkId=network.networkId,
      genesis=chain.genesisHash.toHex,
      forkHash=forkId.forkHash.toHex, forkNext=forkId.forkNext

    let m = await peer.status(ethVersion,
                              network.networkId,
                              totalDifficulty,
                              bestBlock.blockHash,
                              chain.genesisHash,
                              forkId,
                              timeout = chronos.seconds(10))

    when trEthTraceHandshakesOk:
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
      raise newException(
        UselessPeerError, "Eth handshake for different network")

    if m.genesisHash != chain.genesisHash:
      trace "Peer for a different network (genesisHash)", peer,
        expectGenesis=chain.genesisHash.toHex, gotGenesis=m.genesisHash.toHex
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
                forkId: ForkId) =
      trace trEthRecvReceived & "Status (0x00)", peer,
          networkId, totalDifficulty, bestHash, genesisHash,
         forkHash=forkId.forkHash.toHex, forkNext=forkId.forkNext

  # User message 0x01: NewBlockHashes.
  proc newBlockHashes(peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) =
    when trEthTraceGossipOk:
      trace trEthRecvDiscarding & "NewBlockHashes (0x01)", peer,
        hashes=hashes.len
    discard

  # User message 0x02: Transactions.
  proc transactions(peer: Peer, transactions: openArray[Transaction]) =
    when trEthTraceGossipOk:
      trace trEthRecvDiscarding & "Transactions (0x02)", peer,
        transactions=transactions.len
    discard

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

      let headers = peer.network.chain.getBlockHeaders(request)
      if headers.len > 0:
        trace trEthSendReplying & "with BlockHeaders (0x04)", peer,
          sent=headers.len, requested=request.maxResults
      else:
        trace trEthSendReplying & "EMPTY BlockHeaders (0x04)", peer,
          sent=0, requested=request.maxResults

      await response.send(headers)

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

      let bodies = peer.network.chain.getBlockBodies(hashes)
      if bodies.len > 0:
        trace trEthSendReplying & "with BlockBodies (0x06)", peer,
          sent=bodies.len, requested=hashes.len
      else:
        trace trEthSendReplying & "EMPTY BlockBodies (0x06)", peer,
          sent=0, requested=hashes.len

      await response.send(bodies)

    # User message 0x06: BlockBodies.
    proc blockBodies(peer: Peer, blocks: openArray[BlockBody])

  # User message 0x07: NewBlock.
  proc newBlock(peer: Peer, bh: EthBlock, totalDifficulty: DifficultyInt) =
    # (Note, needs to use `EthBlock` instead of its alias `NewBlockAnnounce`
    # because either `p2pProtocol` or RLPx doesn't work with an alias.)
    when trEthTraceGossipOk:
      trace trEthRecvDiscarding & "NewBlock (0x07)", peer,
        totalDifficulty,
        blockNumber = bh.header.blockNumber,
        blockDifficulty = bh.header.difficulty
    discard

  # User message 0x08: NewPooledTransactionHashes.
  proc newPooledTransactionHashes(peer: Peer, txHashes: openArray[Hash256]) =
    when trEthTraceGossipOk:
      trace trEthRecvDiscarding & "NewPooledTransactionHashes (0x08)", peer,
        hashes=txHashes.len
    discard

  requestResponse:
    # User message 0x09: GetPooledTransactions.
    proc getPooledTransactions(peer: Peer, txHashes: openArray[Hash256]) =
      trace trEthRecvReceived & "GetPooledTransactions (0x09)", peer,
        hashes=txHashes.len

      trace trEthSendReplying & "EMPTY PooledTransactions (0x10)", peer,
        sent=0, requested=txHashes.len
      await response.send([])

    # User message 0x0a: PooledTransactions.
    proc pooledTransactions(peer: Peer, transactions: openArray[Transaction])

  # User message 0x0d: GetNodeData -- removed, was so 66ish
  # User message 0x0e: NodeData -- removed, was so 66ish

  nextId 0x0f

  requestResponse:
    # User message 0x0f: GetReceipts.
    proc getReceipts(peer: Peer, hashes: openArray[Hash256]) =
      trace trEthRecvReceived & "GetReceipts (0x0f)", peer,
        hashes=hashes.len

      trace trEthSendReplying & "EMPTY Receipts (0x10)", peer,
        sent=0, requested=hashes.len
      await response.send([])
      # TODO: implement `getReceipts` and reactivate this code
      # await response.send(peer.network.chain.getReceipts(hashes))

    # User message 0x10: Receipts.
    proc receipts(peer: Peer, receipts: openArray[Receipt])

# Nimbus - Ethereum Wire Protocol, version eth/65
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module implements `eth/66`, the `Ethereum Wire Protocol version 66
##   <https://github.com/ethereum/devp2p/blob/master/caps/eth.md>`_
##
## Optional peply processor function hooks
## ---------------------------------------
##
## The `onGetNodeData` and `onNodeData` hooks allow new sync code to register
## for providing reply data or consume incoming events without a circular
## import dependency involving the `p2pProtocol`.
##
## Without the hooks, the protocol file needs to import functions that consume
## incoming network messages. So the `p2pProtocol` can call them, and the
## functions that produce outgoing network messages need to import the protocol
## file.
##
## But related producer/consumer function pairs are typically located in the
## very same file because they are closely related.  For an example see the
## producer of `GetNodeData` and the consumer of `NodeData`.
##
## In this specific case, we need to split the `requestResponse` relationship
## between `GetNodeData` and `NodeData` messages when pipelining.
##
## Among others, this way is the most practical to acomplish the split
## implementation. It allows different protocol-using modules to coexist
## easily.  When the hooks aren't set, default behaviour applies.

import
  chronicles,
  chronos,
  eth/[common/eth_types_rlp, p2p, p2p/private/p2p_types, p2p/blockchain_utils],
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

  PeerState* = ref object
    initialized*: bool
    bestBlockHash*: Hash256
    bestDifficulty*: DifficultyInt

    onGetNodeData*:
      proc (peer: Peer, hashes: openArray[Hash256],
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

  # Pickeled tracer texts
  trEthRecvReceived* =
    "<< " & prettyEthProtoName & " Received "
  trEthRecvReceivedBlockHeaders* =
    trEthRecvReceived & "BlockHeaders (0x04)"
  trEthRecvReceivedBlockBodies* =
    trEthRecvReceived & "BlockBodies (0x06)"
  trEthRecvReceivedGetNodeData* =
    trEthRecvReceived & "GetNodeData (0x0d)"
  trEthRecvReceivedNodeData* =
    trEthRecvReceived & "NodeData (0x0e)"

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
  trEthSendReplyingNodeData* =
    trEthSendReplying & "NodeData (0x0e)"

  trEthSendDelaying* =
    ">> " & prettyEthProtoName & " Delaying "

func toHex(hash: Hash256): string =
  ## Shortcut for `byteutils.toHex(hash.data)`
  hash.data.toHex

func traceStep(request: BlocksRequest): string =
  var str = if request.reverse: "-" else: "+"
  if request.skip < high(typeof(request.skip)):
    return str & $(request.skip + 1)
  return static($(high(typeof(request.skip)).u256 + 1))

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

    trace trEthSendSending & "Status (0x00)", peer,
      td=bestBlock.difficulty,
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
        let
          startBlock =
            if request.startBlock.isHash: request.startBlock.hash.toHex
            else: '#' & $request.startBlock.number
          step =
            if request.maxResults == 1: "n/a"
            else: $request.traceStep
        trace trEthRecvReceived & "GetBlockHeaders (0x03)", peer,
          startBlock, count=request.maxResults, step

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

  nextId 0x0d

  # User message 0x0d: GetNodeData.
  proc getNodeData(peer: Peer, nodeHashes: openArray[Hash256]) =
    trace trEthRecvReceivedGetNodeData, peer,
      hashes=nodeHashes.len

    var data: seq[Blob]
    if not peer.state.onGetNodeData.isNil:
      peer.state.onGetNodeData(peer, nodeHashes, data)
    else:
      data = peer.network.chain.getStorageNodes(nodeHashes)

    trace trEthSendReplyingNodeData, peer,
      sent=data.len, requested=nodeHashes.len

    await peer.nodeData(data)

  # User message 0x0e: NodeData.
  proc nodeData(peer: Peer, data: openArray[Blob]) =
    if not peer.state.onNodeData.isNil:
      # The `onNodeData` should do its own `tracePacket`, because we don't
      # know if this is a valid reply ("Got reply") or something else.
      peer.state.onNodeData(peer, data)
    else:
      trace trEthRecvDiscarding & "NodeData (0x0e)", peer,
        bytes=data.len

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

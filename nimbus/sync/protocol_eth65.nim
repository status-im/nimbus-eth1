# Nimbus - Ethereum Wire Protocol, version eth/65
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module implements Ethereum Wire Protocol version 65, `eth/65`.
## Specification:
##   https://github.com/ethereum/devp2p/blob/master/caps/eth.md

import
  chronos, stint, chronicles, stew/byteutils, macros,
  eth/[common/eth_types, rlp, p2p],
  eth/p2p/[rlpx, private/p2p_types, blockchain_utils],
  ../p2p/chain

type
  NewBlockHashesAnnounce* = object
    hash: KeccakHash
    number: uint64           # Note: Was `uint`, wrong on 32-bit targets.

  NewBlockAnnounce* = EthBlock

  ForkId* = object
    forkHash: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext: BlockNumber    # The RLP encoding must be variable-length

  PeerState = ref object
    initialized*: bool
    bestBlockHash*: KeccakHash
    bestDifficulty*: DifficultyInt

const
  maxStateFetch* = 384
  maxBodiesFetch* = 128
  maxReceiptsFetch* = 256
  maxHeadersFetch* = 192
  ethVersion = 65

func toHex(x: KeccakHash): string = x.data.toHex

p2pProtocol eth(version = ethVersion,
                peerState = PeerState,
                useRequestIds = false):

  onPeerConnected do (peer: Peer):
    let
      network = peer.network
      chain = network.chain
      bestBlock = chain.getBestBlockHeader
      chainForkId = chain.getForkId(bestBlock.blockNumber)
      forkId = ForkId(
        forkHash: chainForkId.crc.toBytesBe,
        forkNext: chainForkId.nextFork.u256,
      )

    let m = await peer.status(ethVersion,
                              network.networkId,
                              bestBlock.difficulty,
                              bestBlock.blockHash,
                              chain.genesisHash,
                              forkId,
                              timeout = chronos.seconds(10))

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
                bestHash: KeccakHash,
                genesisHash: KeccakHash,
                forkId: ForkId)

  # User message 0x01: NewBlockHashes.
  proc newBlockHashes(peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) =
    discard

  # User message 0x02: Transactions.
  proc transactions(peer: Peer, transactions: openArray[Transaction]) =
    discard

  requestResponse:
    # User message 0x03: GetBlockHeaders.
    proc getBlockHeaders(peer: Peer, request: BlocksRequest) =
      if request.maxResults > uint64(maxHeadersFetch):
        await peer.disconnect(BreachOfProtocol)
        return

      await response.send(peer.network.chain.getBlockHeaders(request))

    # User message 0x04: BlockHeaders.
    proc blockHeaders(p: Peer, headers: openArray[BlockHeader])

  requestResponse:
    # User message 0x05: GetBlockBodies.
    proc getBlockBodies(peer: Peer, hashes: openArray[KeccakHash]) =
      if hashes.len > maxBodiesFetch:
        await peer.disconnect(BreachOfProtocol)
        return

      await response.send(peer.network.chain.getBlockBodies(hashes))

    # User message 0x06: BlockBodies.
    proc blockBodies(peer: Peer, blocks: openArray[BlockBody])

  # User message 0x07: NewBlock.
  proc newBlock(peer: Peer, bh: EthBlock, totalDifficulty: DifficultyInt) =
    # (Note, needs to use `EthBlock` instead of its alias `NewBlockAnnounce`
    # because either `p2pProtocol` or RLPx doesn't work with an alias.)
    discard

  # User message 0x08: NewPooledTransactionHashes.
  proc newPooledTransactionHashes(peer: Peer, hashes: openArray[KeccakHash]) =
    discard

  requestResponse:
    # User message 0x09: GetPooledTransactions.
    proc getPooledTransactions(peer: Peer, hashes: openArray[KeccakHash]) =
      await response.send([])

    # User message 0x0a: PooledTransactions.
    proc pooledTransactions(peer: Peer, transactions: openArray[Transaction])

  nextId 0x0d

  requestResponse:
    # User message 0x0d: GetNodeData.
    proc getNodeData(peer: Peer, hashes: openArray[KeccakHash]) =
      await response.send(peer.network.chain.getStorageNodes(hashes))

    # User message 0x0e: NodeData.
    proc nodeData(peer: Peer, data: openArray[Blob])

  requestResponse:
    # User message 0x0f: GetReceipts.
    proc getReceipts(peer: Peer, hashes: openArray[KeccakHash]) =
      await response.send([])
      # TODO: implement `getReceipts` and reactivate this code
      # await response.send(peer.network.chain.getReceipts(hashes))

    # User message 0x10: Receipts.
    proc receipts(peer: Peer, receipts: openArray[Receipt])

# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronos,
  eth/common,
  ../../execution_chain/networking/p2p

# for testing purpose
# real eth protocol implementation is in nimbus-eth1 repo

type
  PeerState = ref object of RootRef
    initialized*: bool

p2pProtocol eth(version = 63,
                peerState = PeerState,
                useRequestIds = false):

  onPeerConnected do (peer: Peer):
    let
      network = peer.network

    discard await peer.status(63,
                              network.networkId,
                              0.u256,
                              default(Hash32),
                              default(Hash32),
                              timeout = chronos.seconds(10))

  handshake:
    proc status(peer: Peer,
                protocolVersion: uint,
                networkId: NetworkId,
                totalDifficulty: DifficultyInt,
                bestHash: Hash32,
                genesisHash: Hash32)

  requestResponse:
    proc getBlockHeaders(peer: Peer, request: openArray[Hash32]) {.gcsafe.} =
      var headers: seq[Header]
      await response.send(headers)

    proc blockHeaders(p: Peer, headers: openArray[Header])

  requestResponse:
    proc getBlockBodies(peer: Peer, hashes: openArray[Hash32]) {.gcsafe.} = discard
    proc blockBodies(peer: Peer, blocks: openArray[BlockBody])

  nextID 13

  requestResponse:
    proc getNodeData(peer: Peer, hashes: openArray[Hash32]) = discard
    proc nodeData(peer: Peer, data: openArray[seq[byte]])

  requestResponse:
    proc getReceipts(peer: Peer, hashes: openArray[Hash32]) = discard
    proc receipts(peer: Peer, receipts: openArray[Receipt])

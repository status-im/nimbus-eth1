# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  chronos, testutils/unittests,
  ../../execution_chain/networking/p2p,
  ./stubloglevel,
  ./p2p_test_helper

type
  network = ref object of RootRef
    count*: int

  PeerState = ref object of RootRef
    status*: string

p2pProtocol abc(version = 1,
                rlpxName = "abc",
                networkState = network):

  onPeerConnected do (peer: Peer):
    peer.networkState.count += 1

  onPeerDisconnected do (peer: Peer, reason: DisconnectionReason) {.gcsafe.}:
    peer.networkState.count -= 1

p2pProtocol xyz(version = 1,
                rlpxName = "xyz",
                networkState = network,
                peerState = PeerState):

  onPeerConnected do (peer: Peer):
    peer.networkState.count += 1
    peer.state.status = "connected"

  onPeerDisconnected do (peer: Peer, reason: DisconnectionReason) {.gcsafe.}:
    peer.networkState.count -= 1
    peer.state.status = "disconnected"

p2pProtocol hah(version = 1,
                rlpxName = "hah",
                networkState = network):

  onPeerConnected do (peer: Peer):
    if true:
      raise newException(UselessPeerError, "Fake hah exception")
    peer.networkState.count += 1

  onPeerDisconnected do (peer: Peer, reason: DisconnectionReason) {.gcsafe.}:
    peer.networkState.count -= 1


suite "Testing protocol handlers":
  asyncTest "Failing disconnection handler":
    let rng = newRng()

    var node1 = setupTestNode(rng, abc, xyz)
    var node2 = setupTestNode(rng, abc, xyz)

    node2.startListening()
    let res = await node1.rlpxConnect(newNode(node2.toENode()))
    check res.isOk()
    let peer = res.get()
    check peer.state(xyz).status == "connected"

    await peer.disconnect(SubprotocolReason, true)
    check:
      # all disconnection handlers are called
      node1.protocolState(abc).count == 0
      node1.protocolState(xyz).count == 0
      peer.state(xyz).status == "disconnected"

  asyncTest "Failing connection handler":
    let rng = newRng()

    var node1 = setupTestNode(rng, hah)
    var node2 = setupTestNode(rng, hah)
    node2.startListening()
    let res = await node1.rlpxConnect(newNode(node2.toENode()))
    check:
      res.isErr()
      # To check if the disconnection handler did not run
      node1.protocolState(hah).count == 0

  test "Override network state":
    let rng = newRng()
    var node = setupTestNode(rng, hah)
    node.addCapability(hah, network(count: 3))
    check node.protocolState(hah).count == 3
    node.replaceNetworkState(hah, network(count: 7))
    check node.protocolState(hah).count == 7

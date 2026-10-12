# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  unittest2,
  testutils,
  chronos,
  ../../execution_chain/networking/p2p,
  ../../execution_chain/sync/wire_protocol,
  ./stubloglevel,
  ./p2p_test_helper

const timeout = chronos.seconds(3)

func testHash(b: byte): Hash32 =
  var data: array[32, byte]
  data[31] = b
  Hash32(data)

procSuite "devp2p snap Tests":
  asyncTest "snap/2 requests are answered":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    discard env1.node.addSnapHandlerCapability()
    discard env2.node.addSnapHandlerCapability()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    # Both nodes offer snap/1 and snap/2; the handshake keeps snap/2 only.
    let peer = connRes.get()
    check:
      peer.supports(snap2)
      not peer.supports(snap1)

      (await peer.getAccountRange(AccountRangeRequest(
        rootHash: testHash(1), startingHash: testHash(2), limitHash: testHash(3),
        responseBytes: 1024), timeout)).isSome()
      (await peer.getStorageRanges(StorageRangesRequest(
        rootHash: testHash(1), accountHashes: @[testHash(4)], startingHash: testHash(2),
        limitHash: testHash(3), responseBytes: 1024), timeout)).isSome()
      (await peer.getByteCodes(ByteCodesRequest(
        hashes: @[testHash(5), testHash(6)], bytes: 1024), timeout)).isSome()
      (await snap.getBlockAccessLists(peer, SnapBalRequest(
        blockHashes: @[testHash(7)], bytes: 1024), timeout)).isSome()
      peer.connectionState == ConnectionState.Connected

    await env2.close()
    await env1.close()

  asyncTest "snap/1 requests are answered":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env1.node.addCapability(snap1, SnapWireStateRef())
    env2.node.addCapability(snap1, SnapWireStateRef())

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check:
      peer.supports(snap1)
      not peer.supports(snap2)

      (await peer.getAccountRange(AccountRangeRequest(
        rootHash: testHash(1), startingHash: testHash(2), limitHash: testHash(3),
        responseBytes: 1024), timeout)).isSome()
      (await peer.getStorageRanges(StorageRangesRequest(
        rootHash: testHash(1), accountHashes: @[testHash(4)], startingHash: testHash(2),
        limitHash: testHash(3), responseBytes: 1024), timeout)).isSome()
      (await peer.getByteCodes(ByteCodesRequest(
        hashes: @[testHash(5), testHash(6)], bytes: 1024), timeout)).isSome()
      (await peer.getTrieNodes(TrieNodesRequest(
        rootHash: testHash(1), paths: @[@[AccountOrSlotPath(@[0x12.byte])]],
        bytes: 1024), timeout)).isSome()
      peer.connectionState == ConnectionState.Connected

    await env2.close()
    await env1.close()

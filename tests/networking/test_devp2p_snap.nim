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
  std/[sequtils, typetraits],
  unittest2,
  testutils,
  chronos,
  ../../execution_chain/networking/p2p,
  ../../execution_chain/sync/wire_protocol,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/db/core_db,
  ../../execution_chain/db/core_db/core_apps,
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

    discard env1.node.addSnapHandlerCapability(env1.chain)
    discard env2.node.addSnapHandlerCapability(env2.chain)

    # Stored empty BAL, encoded `0xc0`, distinct from the `0x80` placeholder.
    env2.chain.latestTxFrame.persistBlockAccessList(testHash(7), new BlockAccessList)

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
      # Served like `eth/71`: request order kept, `0x80` for an unavailable BAL.
      (await snap.getBlockAccessLists(peer, SnapBalRequest(
        blockHashes: @[testHash(7), testHash(8)], bytes: 1024), timeout))
        .expect("reply").accessLists.mapIt(it.distinctBase) ==
          @[@[0xc0'u8], @[0x80'u8]]
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

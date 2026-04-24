# nimbus-execution-client
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  std/typetraits,
  unittest2,
  testutils,
  chronos,
  eth/[common, rlp],
  stew/endians2,
  ../../execution_chain/networking/p2p,
  ../../execution_chain/sync/wire_protocol,
  ../../execution_chain/sync/wire_protocol/eth/eth_handler,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/db/core_db,
  ../../execution_chain/db/core_db/core_apps,
  ./stubloglevel,
  ./p2p_test_helper

const
  UNAVAILABLE_BAL_BYTES = @[0x80.byte]
  EMPTY_BAL_BYTES       = @[0xc0.byte]

proc seedBal(env: TestEnv, hash: Hash32, bal: BlockAccessList) =
  let balToStore: BlockAccessListRef = new BlockAccessList
  balToStore[] = bal

  env.chain.latestTxFrame.persistBlockAccessList(hash, balToStore)

func makeHash(i: int): Hash32 =
  keccak256(i.uint64.toBytesLE)

procSuite "devp2p eth/71 Tests":

  asyncTest "getBlockAccessLists - BAL unavailable":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let
      req = BlockAccessListsRequest(blockHashes: @[default(Hash32)])
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check resp.accessLists.len() == 1

    let balBytes = resp.accessLists[0]
    check:
      distinctBase(balBytes) == UNAVAILABLE_BAL_BYTES
      rlp.encode(balBytes) == UNAVAILABLE_BAL_BYTES

    env2.close()
    env1.close()

  asyncTest "getBlockAccessLists - empty BAL available":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let blockHash = makeHash(2)
    seedBal(env2, blockHash, default(BlockAccessList))

    let
      req = BlockAccessListsRequest(blockHashes: @[blockHash])
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check resp.accessLists.len() == 1

    let balBytes = resp.accessLists[0].distinctBase()
    check:
      balBytes == EMPTY_BAL_BYTES
      BlockAccessList.decode(balBytes).expect("valid BAL") == default(BlockAccessList)

    env2.close()
    env1.close()

  asyncTest "getBlockAccessLists - non empty BAL available":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let blockHash = makeHash(1)

    var bal: BlockAccessList = newSeq[AccountChanges](1)
    bal[0].address = Address.fromHex("0x1234567890123456789012345678901234567890")
    
    seedBal(env2, blockHash, bal)

    let
      req = BlockAccessListsRequest(blockHashes: @[blockHash])
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check resp.accessLists.len() == 1

    let balBytes = resp.accessLists[0].distinctBase()
    check:
      balBytes.len() > 0
      BlockAccessList.decode(balBytes).expect("valid BAL") == bal

    env2.close()
    env1.close()

  asyncTest "getBlockAccessLists - mixed unavailable, empty and non empty BALs":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let
      unavailableHash = makeHash(3)
      emptyHash       = makeHash(4)
      nonEmptyHash    = makeHash(5)

    let emptyBal = default(BlockAccessList)

    var nonEmptyBal: BlockAccessList = newSeq[AccountChanges](1)
    nonEmptyBal[0].address = Address.fromHex("0x1111111111111111111111111111111111111111")

    seedBal(env2, emptyHash, emptyBal)
    seedBal(env2, nonEmptyHash, nonEmptyBal)

    let
      req = BlockAccessListsRequest(
        blockHashes: @[unavailableHash, emptyHash, nonEmptyHash])
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check resp.accessLists.len() == req.blockHashes.len()

    let
      unavailableBytes = resp.accessLists[0].distinctBase()
      emptyBytes = resp.accessLists[1].distinctBase()
      nonEmptyBytes = resp.accessLists[2].distinctBase()

    check:
      unavailableBytes == UNAVAILABLE_BAL_BYTES
      emptyBytes == EMPTY_BAL_BYTES
      BlockAccessList.decode(emptyBytes).expect("valid BAL") == emptyBal
      BlockAccessList.decode(nonEmptyBytes).expect("valid BAL") == nonEmptyBal

    env2.close()
    env1.close()

  asyncTest "getBlockAccessLists - MAX_BALS_SERVE cap":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let numExtra = 4
    var hashes = newSeq[Hash32](MAX_BALS_SERVE + numExtra)
    for i in 0 ..< hashes.len:
      hashes[i] = makeHash(i)

    let
      req = BlockAccessListsRequest(blockHashes: hashes)
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check resp.accessLists.len() == MAX_BALS_SERVE

    for balBytes in resp.accessLists:
      check distinctBase(balBytes) == UNAVAILABLE_BAL_BYTES

    env2.close()
    env1.close()

  asyncTest "getBlockAccessLists - SOFT_RESPONSE_LIMIT respected":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    # Build several large BALs so the cumulative payload exceeds SOFT_RESPONSE_LIMIT.
    const
      numSeeded = 5
      entriesPerBal = 30_000
    var
      hashes = newSeq[Hash32](numSeeded)
      bals = newSeq[BlockAccessList](numSeeded)

    let testAddress = Address.fromHex("0x1111111111111111111111111111111111111111")
    for i in 0 ..< numSeeded:
      hashes[i] = makeHash(100 + i)
      var bal = newSeq[AccountChanges](entriesPerBal)
      for j in 0 ..< entriesPerBal:
        bal[j].address = testAddress
      bals[i] = bal
      seedBal(env2, hashes[i], bal)

    let
      req = BlockAccessListsRequest(blockHashes: hashes)
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(10))
    check respOpt.isSome()

    let resp = respOpt.get()
    check:
      resp.accessLists.len() > 0
      resp.accessLists.len() < numSeeded

    for i, balBytes in resp.accessLists:
      check BlockAccessList.decode(balBytes.distinctBase()).expect("valid BAL") == bals[i]

    env2.close()
    env1.close()

  asyncTest "getBlockHeaders":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let
      req = BlockHeadersRequest(
        startBlock: BlockHashOrNumber(isHash: false, number: 0),
        maxResults: 1,
        skip: 0,
        reverse: false)
      respOpt = await peer.getBlockHeaders(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check:
      resp.headers.len() == 1
      resp.headers[0].number == 0

    env2.close()
    env1.close()

  asyncTest "getBlockBodies":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let
      req = BlockBodiesRequest(blockHashes: @[env2.chain.latestHash])
      respOpt = await peer.getBlockBodies(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check:
      resp.bodies.len() == 1

    env2.close()
    env1.close()

  asyncTest "getPooledTransactions":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let
      req = PooledTransactionsRequest(txHashes: @[makeHash(777)])
      respOpt = await peer.getPooledTransactions(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check resp.transactions.len() == 0

    env2.close()
    env1.close()

  asyncTest "blockRangeUpdate":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    await peer.blockRangeUpdate(
      BlockRangeUpdatePacket(
        earliest: 0,
        latest: 0,
        latestHash: default(Hash32)))

    # Verify the connection remains usable after sending BlockRangeUpdate.
    let
      req = BlockAccessListsRequest(blockHashes: @[default(Hash32)])
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    env2.close()
    env1.close()

  asyncTest "getReceipts (eth70+ format)":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let
      req = ReceiptsRequest(blockHashes: @[makeHash(888)])
      respOpt = await peer.getReceipts(0'u64, req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check:
      resp.receipts.len() == 0
      resp.lastBlockIncomplete

    env2.close()
    env1.close()
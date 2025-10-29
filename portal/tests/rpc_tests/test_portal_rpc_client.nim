# Nimbus - Portal Network
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos,
  testutils/unittests,
  json_rpc/rpcserver,
  json_rpc/clients/httpclient,
  stint,
  eth/enr/enr,
  eth/common/keys,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../../network/history/[history_network, history_content, history_validation],
  ../../database/content_db,
  ../../rpc/[portal_rpc_client, rpc_portal_history_api],
  ../test_helpers

type HistoryNode = ref object
  discv5*: discv5_protocol.Protocol
  historyNetwork*: HistoryNetwork

proc newHistoryNode(rng: ref HmacDrbgContext, port: int): HistoryNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new(
      "",
      uint32.high,
      RadiusConfig(kind: Dynamic),
      node.localNode.id,
      PortalSubnetwork.history,
      inMemory = true,
    )
    streamManager = StreamManager.new(node)
    historyNetwork = HistoryNetwork.new(PortalNetwork.mainnet, node, db, streamManager)

  return HistoryNode(discv5: node, historyNetwork: historyNetwork)

proc portalProtocol(hn: HistoryNode): PortalProtocol =
  hn.historyNetwork.portalProtocol

proc localNode(hn: HistoryNode): Node =
  hn.discv5.localNode

proc start(hn: HistoryNode) =
  hn.historyNetwork.start()

proc stop(hn: HistoryNode) {.async.} =
  discard hn.historyNetwork.stop()
  await hn.discv5.closeWait()

proc store*(hn: HistoryNode, blockNumber: uint64, blockBody: BlockBody) =
  let
    contentKey = blockBodyContentKey(blockNumber)
    contentId = history_content.toContentId(contentKey)

  hn.portalProtocol().storeContent(contentKey.encode(), contentId, blockBody.encode())

proc store*(hn: HistoryNode, blockNumber: uint64, receipts: seq[StoredReceipt]) =
  let
    contentKey = receiptsContentKey(blockNumber)
    contentId = history_content.toContentId(contentKey)

  hn.portalProtocol().storeContent(contentKey.encode(), contentId, receipts.encode())

type TestCase = ref object
  historyNode1: HistoryNode
  historyNode2: HistoryNode
  server: RpcHttpServer
  client: PortalRpcClient

proc setupTest(rng: ref HmacDrbgContext): Future[TestCase] {.async.} =
  let
    localSrvAddress = "127.0.0.1"
    localSrvPort = 0 # let the OS choose a port
    ta = initTAddress(localSrvAddress, localSrvPort)
    client = newRpcHttpClient()
    historyNode1 = newHistoryNode(rng, 20333)
    historyNode2 = newHistoryNode(rng, 20334)

  historyNode1.start()
  historyNode2.start()

  check:
    historyNode1.portalProtocol().addNode(historyNode2.localNode()) == Added
    historyNode2.portalProtocol().addNode(historyNode1.localNode()) == Added

  let rpcHttpServer = RpcHttpServer.new()
  rpcHttpServer.addHttpServer(ta, maxRequestBodySize = 16 * 1024 * 1024)
  rpcHttpServer.installPortalHistoryApiHandlers(historyNode1.historyNetwork)
  rpcHttpServer.start()

  await client.connect(localSrvAddress, rpcHttpServer.localAddress[0].port, false)

  return TestCase(
    historyNode1: historyNode1,
    historyNode2: historyNode2,
    server: rpcHttpServer,
    client: PortalRpcClient.init(client),
  )

proc stop(testCase: TestCase) {.async.} =
  await testCase.server.stop()
  await testCase.server.closeWait()
  await testCase.historyNode1.stop()
  await testCase.historyNode2.stop()

procSuite "Portal RPC Client":
  let rng = newRng()

  asyncTest "Test historyGetBlockBody":
    let
      tc = await setupTest(rng)
      blockNumber = 300'u64
      blockHeader = Header(number: blockNumber)
      blockBody = BlockBody()

    # Test content not found
    block:
      let blockBodyRes = await tc.client.historyGetBlockBody(blockHeader)
      check:
        blockBodyRes.isErr()
        blockBodyRes.error().code == ContentNotFoundError.code

    # Test content validation failed
    block:
      tc.historyNode2.store(blockNumber, blockBody)

      let blockBodyRes = await tc.client.historyGetBlockBody(blockHeader)
      check:
        blockBodyRes.isErr()
        blockBodyRes.error().code == ContentNotFoundError.code

    # When local node has the content the validation is skipped
    block:
      tc.historyNode1.store(blockNumber, blockBody)

      let blockBodyRes = await tc.client.historyGetBlockBody(blockHeader)
      check:
        blockBodyRes.isOk()

    waitFor tc.stop()

  asyncTest "Test historyGetReceipts":
    let
      tc = await setupTest(rng)
      blockNumber = 300'u64
      blockHeader = Header(number: blockNumber)
      receipts = @[StoredReceipt()]

    # Test content not found
    block:
      let receiptsRes = await tc.client.historyGetReceipts(blockHeader)
      check:
        receiptsRes.isErr()
        receiptsRes.error().code == ContentNotFoundError.code

    # Test content validation failed
    block:
      tc.historyNode2.store(blockNumber, receipts)

      let receiptsRes = await tc.client.historyGetReceipts(blockHeader)
      check:
        receiptsRes.isErr()
        receiptsRes.error().code == ContentNotFoundError.code

    # When local node has the content the validation is skipped
    block:
      tc.historyNode1.store(blockNumber, receipts)

      let receiptsRes = await tc.client.historyGetReceipts(blockHeader)
      check:
        receiptsRes.isOk()

    waitFor tc.stop()

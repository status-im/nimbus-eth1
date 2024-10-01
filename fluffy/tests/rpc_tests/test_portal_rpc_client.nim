# Nimbus - Portal Network
# Copyright (c) 2021-2024 Status Research & Development GmbH
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
  eth/p2p/discoveryv5/enr,
  eth/keys,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../rpc/rpc_discovery_api,
  ../test_helpers,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  eth/common/eth_types_rlp,
  eth/rlp,
  ../../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../../network/history/
    [history_network, history_content, validation/historical_hashes_accumulator],
  ../../database/content_db,
  ../../rpc/[portal_rpc_client, rpc_portal_api]

type HistoryNode = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  historyNetwork*: HistoryNetwork

proc newHistoryNode(rng: ref HmacDrbgContext, port: int): HistoryNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new(
      "", uint32.high, RadiusConfig(kind: Dynamic), node.localNode.id, inMemory = true
    )
    streamManager = StreamManager.new(node)
    historyNetwork = HistoryNetwork.new(
      PortalNetwork.none, node, db, streamManager, FinishedHistoricalHashesAccumulator()
    )

  return HistoryNode(discoveryProtocol: node, historyNetwork: historyNetwork)

proc portalProtocol(hn: HistoryNode): PortalProtocol =
  hn.historyNetwork.portalProtocol

proc localNode(hn: HistoryNode): Node =
  hn.discoveryProtocol.localNode

proc start(hn: HistoryNode) =
  hn.historyNetwork.start()

proc stop(hn: HistoryNode) {.async.} =
  discard hn.historyNetwork.stop()
  await hn.discoveryProtocol.closeWait()

proc containsId(hn: HistoryNode, contentId: ContentId): bool =
  return hn.historyNetwork.contentDB.get(contentId).isSome()

proc store*(
    hn: HistoryNode, blockHash: BlockHash, blockHeader: BlockHeader) =
  let
    headerRlp = rlp.encode(blockHeader)
    blockHeaderWithProof = BlockHeaderWithProof(
      header: ByteList[2048].init(headerRlp), proof: BlockHeaderProof.init()
    )
    contentKeyBytes = blockHeaderContentKey(blockHash).encode()
    contentId = history_content.toContentId(contentKeyBytes)

  hn.portalProtocol().storeContent(
    contentKeyBytes, contentId, SSZ.encode(blockHeaderWithProof)
  )

type TestCase = ref object
  historyNode: HistoryNode
  server: RpcHttpServer
  client: PortalRpcClient

proc setupTest(rng: ref HmacDrbgContext): Future[TestCase] {.async.} =
  let
    localSrvAddress = "127.0.0.1"
    localSrvPort = 0 # let the OS choose a port
    ta = initTAddress(localSrvAddress, localSrvPort)
    client = newRpcHttpClient()
    historyNode = newHistoryNode(rng, 20302)

  let rpcHttpServer = RpcHttpServer.new()
  rpcHttpServer.addHttpServer(ta, maxRequestBodySize = 4 * 1_048_576)
  rpcHttpServer.installPortalApiHandlers(
    historyNode.historyNetwork.portalProtocol, "history"
  )
  rpcHttpServer.start()

  await client.connect(localSrvAddress, rpcHttpServer.localAddress[0].port, false)

  return TestCase(
    historyNode: historyNode,
    server: rpcHttpServer,
    client: PortalRpcClient.init(client),
  )

proc stop(testCase: TestCase) {.async.} =
  await testCase.server.stop()
  await testCase.server.closeWait()
  await testCase.historyNode.stop()

procSuite "Portal RPC Client":
  let rng = newRng()

  asyncTest "Test historyGetBlockHeader with validation":
    let
      tc = await setupTest(rng)
      blockHeader = BlockHeader(number: 100)
      blockHash = blockHeader.blockHash()

    # Test content not found
    block:
      let blockHeaderRes = await tc.client.historyGetBlockHeader(blockHash, validateContent = true)
      check:
        blockHeaderRes.isErr()
        blockHeaderRes.error() == ContentNotFound

    # Test content found
    block:
      tc.historyNode.store(blockHash, blockHeader)

      let blockHeaderRes = await tc.client.historyGetBlockHeader(blockHash, validateContent = true)
      check:
        blockHeaderRes.isOk()
        blockHeaderRes.value() == blockHeader

    # Test content validation failed
    block:
      tc.historyNode.store(blockHash, BlockHeader()) # bad header

      let blockHeaderRes = await tc.client.historyGetBlockHeader(blockHash, validateContent = true)
      check:
        blockHeaderRes.isErr()
        blockHeaderRes.error() == ContentValidationFailed
    waitFor tc.stop()

  asyncTest "Test historyGetBlockHeader without validation":
    let
      tc = await setupTest(rng)
      blockHeader = BlockHeader(number: 200)
      blockHash = blockHeader.blockHash()

    # Test content not found
    block:
      let blockHeaderRes = await tc.client.historyGetBlockHeader(blockHash, validateContent = false)
      check:
        blockHeaderRes.isErr()
        blockHeaderRes.error() == ContentNotFound

    tc.historyNode.store(blockHash, blockHeader)

    # Test content found
    block:
      let blockHeaderRes = await tc.client.historyGetBlockHeader(blockHash, validateContent = false)
      check:
        blockHeaderRes.isOk()
        blockHeaderRes.value() == blockHeader

    waitFor tc.stop()
